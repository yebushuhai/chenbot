import 'dart:math';

import 'package:chenbot/adaptive.dart';
import 'package:chenbot/english_level.dart';
import 'package:chenbot/english_level_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('band names and ranges use the requested inclusive lower bounds', () {
    expect(chenbotBands.map((b) => b.label).toList(), [
      '文盲',
      '菜鸡',
      '青铜',
      '白银',
      '黄金',
      '钻石',
      '莎士比亚',
    ]);
    expect(chenbotBands.map((b) => b.reference).toList(), [
      '0–1,999 词',
      '2,000–7,999 词',
      '8,000–14,999 词',
      '15,000–19,999 词',
      '20,000–29,999 词',
      '30,000–49,999 词',
      '50,000 词及以上',
    ]);
  });

  test('question difficulties use the pinned subtitle ranks', () {
    expect(englishQuestions.length, greaterThanOrEqualTo(180));
    expect(
      englishQuestions.map((q) => q.word).toSet().length,
      englishQuestions.length,
    );
    for (final level in Level.values) {
      expect(
        englishQuestions.where((q) => q.level == level).length,
        greaterThanOrEqualTo(2),
      );
    }
    for (final question in englishQuestions) {
      expect({question.meaning, ...question.distractors}.length, 4);
    }
    final meticulous = englishQuestions.singleWhere(
      (q) => q.word == 'meticulous',
    );
    expect(meticulous.frequencyRank, 17781);
    expect(meticulous.level, subtitleLevelForRank(17781));
    expect(subtitleLevelForRank(1000), Level.h);
    expect(subtitleLevelForRank(1001), Level.g);
    expect(() => subtitleLevelForRank(0), throwsArgumentError);
  });

  test('word-form to candidate-unit crosswalk has documented boundaries', () {
    expect(candidateUnitsForRank(20000), 15322);
    expect(candidateUnitsForRank(30000), 23072);
    expect(candidateUnitsForRank(50000), 39317);
    expect(candidateUnitsForRank(26000), greaterThan(19000));
    expect(candidateUnitsForRank(26000), lessThan(21000));
  });

  testWidgets('test introduction keeps only the requested description', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: EnglishLevelPage(scope: 'guest')),
    );
    expect(find.text('英语水平测试'), findsOneWidget);
    expect(find.text('共12道自适应难度选择题'), findsOneWidget);
    expect(find.text('开始测试'), findsOneWidget);
    expect(find.textContaining('完成后会给出'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  test('adaptive sessions respond to answers and never repeat questions', () {
    final high = AdaptiveEnglishSession(random: Random(4));
    final low = AdaptiveEnglishSession(random: Random(4));
    expect(high.next().word, low.next().word);
    high.answer(true);
    low.answer(false, unsure: true);
    expect(high.next().frequencyRank, greaterThan(low.next().frequencyRank));

    for (final level in Level.values) {
      final session = AdaptiveEnglishSession(random: Random(level.index));
      while (!session.finished) {
        final question = session.next();
        expect(question.frequencyRank, lessThanOrEqualTo(50000));
        session.answer(question.level.index <= level.index);
      }
      expect(session.asked.length, 12);
      expect(session.asked.map((q) => q.word).toSet().length, 12);
      expect(session.answers.length, 12);
      expect(session.correct, session.answers.where((a) => a.correct).length);
      expect(() => session.next(), throwsStateError);
    }
  });

  test('an unknown word does not incur an extra uncalibrated penalty', () {
    final incorrect = AdaptiveEnglishSession(random: Random(42));
    final unknown = AdaptiveEnglishSession(random: Random(42));
    for (var i = 0; i < AdaptiveEnglishSession.questionCount; i++) {
      expect(incorrect.next().word, unknown.next().word);
      final answeredCorrectly = i % 3 == 0;
      incorrect.answer(answeredCorrectly);
      unknown.answer(answeredCorrectly, unsure: !answeredCorrectly);
    }
    expect(unknown.answers.where((answer) => answer.unsure).length, 8);
    expect(incorrect.result.lower, unknown.result.lower);
    expect(incorrect.result.upper, unknown.result.upper);
    expect(incorrect.result.recommended, unknown.result.recommended);
  });

  test('mixed frequency evidence does not produce a single grade', () {
    final session = AdaptiveEnglishSession(random: Random(10));
    final outcomes = Random(1010);
    while (!session.finished) {
      final question = session.next();
      final chance = question.frequencyRank > 22000 ? .8 : .45;
      session.answer(outcomes.nextDouble() < chance);
    }
    expect(session.result.frequencyMismatch, isTrue);
    expect(session.result.recommended, isNull);
    expect(session.result.lower, chenbotBands.first);
    expect(session.result.upper, chenbotBands.last);
  });

  test('a consistent all-correct pattern is not marked as mixed', () {
    final session = AdaptiveEnglishSession(random: Random(5));
    while (!session.finished) {
      session.next();
      session.answer(true);
    }
    expect(session.result.frequencyMismatch, isFalse);
    expect(session.result.recommended, isNull);
  });

  test('adaptive sessions can draw everyday objects across test runs', () {
    const addedObjects = {
      'thermometer',
      'compass',
      'drawer',
      'broom',
      'socket',
      'sponge',
      'funnel',
      'pliers',
      'stroller',
      'sprinkler',
      'thermostat',
      'tripod',
      'bucket',
      'binder',
      'wheelbarrow',
      'stethoscope',
      'saucepan',
      'bookshelf',
      'anchor',
      'lighthouse',
      'refrigerator',
      'chandelier',
      'apron',
      'cork',
      'jar',
      'toothbrush',
      'hammock',
      'binoculars',
      'beaker',
      'telescope',
    };
    final seen = <String>{};
    for (var seed = 0; seed < 30; seed++) {
      final session = AdaptiveEnglishSession(random: Random(seed));
      while (!session.finished) {
        final question = session.next();
        if (addedObjects.contains(question.word)) seen.add(question.word);
        session.answer(question.frequencyRank <= 16000);
      }
    }
    // These are diverse seeded runs of a toy model, not learner calibration.
    expect(seen.length, greaterThanOrEqualTo(5));
  });

  test('migrates old levels by their former lower bound', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('english_level_v1_guest', 'chenbot:s');
    final migrated = await EnglishLevelProfile.load('guest');
    expect(migrated?.band.label, '黄金');
    expect(prefs.getString('english_level_v4_guest'), 'chenbot:b');
    expect(prefs.getString('english_level_v1_guest'), 'chenbot:s');
  });

  test('selected difficulty persists only for the current profile', () async {
    final profile = EnglishLevelProfile(
      chenbotBands.singleWhere((b) => b.id == 'b'),
    );
    await profile.save('guest');
    final restored = await EnglishLevelProfile.load('guest');
    expect(restored?.band.label, '黄金');
    expect(await EnglishLevelProfile.load('another-user'), isNull);
  });

  test(
    'retired scale is not silently converted to a vocabulary grade',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('english_level_v2_guest', 'cefr:b2');
      expect(await EnglishLevelProfile.load('guest'), isNull);
      expect(prefs.getString('english_level_v2_guest'), 'cefr:b2');
    },
  );

  test('migrates the removed level using its original lower bound', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('english_level_v2_guest', 'chenbot:e');
    final migrated = await EnglishLevelProfile.load('guest');
    expect(migrated?.band.label, '菜鸡');
    expect(prefs.getString('english_level_v4_guest'), 'chenbot:f');
    expect(prefs.getString('english_level_v2_guest'), 'chenbot:e');
  });

  test(
    'merges the former 呆子 selection without erasing its old value',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('english_level_v3_guest', 'chenbot:g');
      final migrated = await EnglishLevelProfile.load('guest');
      expect(migrated?.band.label, '菜鸡');
      expect(prefs.getString('english_level_v4_guest'), 'chenbot:f');
      expect(prefs.getString('english_level_v3_guest'), 'chenbot:g');
    },
  );

  test('fivefold word-form mapping uses all seven inclusive boundaries', () {
    expect(englishFrequencyRankScale, 5);
    final cases = <(int, String)>[
      (1, '文盲'),
      (9999, '文盲'),
      (10000, '菜鸡'),
      (39999, '菜鸡'),
      (40000, '青铜'),
      (74999, '青铜'),
      (75000, '白银'),
      (99999, '白银'),
      (100000, '黄金'),
      (149999, '黄金'),
      (150000, '钻石'),
      (249999, '钻石'),
      (250000, '莎士比亚'),
      (500000, '莎士比亚'),
    ];
    for (final (rank, expected) in cases) {
      expect(englishBandForSubtitleRank(rank)?.label, expected);
    }
    expect(englishBandForSubtitleRank(null), isNull);
    expect(englishBandForSubtitleRank(0), isNull);
    for (var i = 0; i < chenbotBands.length; i++) {
      for (var j = 0; j < chenbotBands.length; j++) {
        expect(
          englishBandAllowed(chenbotBands[j], chenbotBands[i]),
          j == i || j == i + 1,
        );
      }
    }
  });

  testWidgets(
    'assessment handles do not know and avoids a false vocabulary estimate',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: AdaptiveEnglishTestPage()),
      );
      for (var i = 0; i < 12; i++) {
        await tester.ensureVisible(find.text('不认识'));
        await tester.tap(find.text('不认识'));
        await tester.pumpAndSettle();
        expect(find.text('已选择不认识'), findsOneWidget);
        expect(find.textContaining('正确答案：'), findsOneWidget);
        final next = find.text(i == 11 ? '查看结果' : '下一题');
        await tester.ensureVisible(next);
        await tester.tap(next);
        await tester.pumpAndSettle();
      }
      expect(find.text('测试完成'), findsOneWidget);
      expect(find.text('暂不能确定单一等级'), findsOneWidget);
      expect(find.textContaining('参考范围（未标定）：'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
    },
  );

  testWidgets('an incorrect choice shows the chosen and correct meanings', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AdaptiveEnglishTestPage()));
    final question = englishQuestions.singleWhere(
      (q) => find.text(q.word).evaluate().isNotEmpty,
    );
    await tester.tap(find.text(question.distractors.first));
    await tester.pumpAndSettle();
    expect(find.text('回答错误'), findsOneWidget);
    expect(find.text('你的选择：${question.distractors.first}'), findsOneWidget);
    expect(find.text('正确答案：${question.meaning}'), findsOneWidget);
    await tester.tap(find.text('下一题'));
    await tester.tap(find.text('下一题'));
    await tester.pumpAndSettle();
    expect(find.text('第 2 / 12 题'), findsOneWidget);
  });

  testWidgets('mixed frequency results preserve the chosen photo level', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('english_level_v3_guest', 'chenbot:b');
    await tester.pumpWidget(const MaterialApp(home: AdaptiveEnglishTestPage()));
    final dynamic state = tester.state(find.byType(AdaptiveEnglishTestPage));
    state.setState(() {
      state.session = AdaptiveEnglishSession(random: Random(10));
      state.prepare();
    });
    await tester.pumpAndSettle();
    final outcomes = Random(1010);
    for (var i = 0; i < 12; i++) {
      final question = (state.session as AdaptiveEnglishSession).current!;
      final chance = question.frequencyRank > 22000 ? .8 : .45;
      final answer = outcomes.nextDouble() < chance
          ? question.meaning
          : question.distractors.first;
      await tester.ensureVisible(find.text(answer));
      await tester.tap(find.text(answer));
      await tester.pumpAndSettle();
      final next = find.text(i == 11 ? '查看结果' : '下一题');
      await tester.ensureVisible(next);
      await tester.tap(next);
      await tester.pumpAndSettle();
    }
    expect(find.text('暂不能确定单一等级'), findsOneWidget);
    expect(find.text('部分回答与字幕词频排序差异较大，暂无法缩小范围。'), findsOneWidget);
    expect((await EnglishLevelProfile.load('guest'))?.band.label, '黄金');
  });

  testWidgets(
    'a ceiling score does not assert Shakespeare or overwrite the chosen grade',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('english_level_v3_guest', 'chenbot:b');
      await tester.pumpWidget(
        const MaterialApp(home: AdaptiveEnglishTestPage()),
      );
      for (var i = 0; i < 12; i++) {
        final dynamic state = tester.state(
          find.byType(AdaptiveEnglishTestPage),
        );
        final question = (state.session as AdaptiveEnglishSession).current!;
        await tester.ensureVisible(find.text(question.meaning));
        await tester.tap(find.text(question.meaning));
        await tester.pumpAndSettle();
        expect(find.text('回答正确'), findsOneWidget);
        final next = find.text(i == 11 ? '查看结果' : '下一题');
        await tester.ensureVisible(next);
        await tester.tap(next);
        await tester.pumpAndSettle();
      }
      expect(find.text('答对 12 / 12 题'), findsOneWidget);
      final dynamic state = tester.state(find.byType(AdaptiveEnglishTestPage));
      final result = (state.session as AdaptiveEnglishSession).result;
      expect(result.recommended, isNull);
      expect(result.upper.label, '莎士比亚');
      expect(find.text('暂不能确定单一等级'), findsOneWidget);
      expect((await EnglishLevelProfile.load('guest'))?.band.label, '黄金');
      expect(find.byType(Checkbox), findsNothing);
    },
  );

  testWidgets('allows selecting a level next to recognition', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: EnglishDifficultySelector(scope: 'guest')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('CEFR 参考'), findsNothing);
    await tester.tap(find.byType(DropdownButton<EnglishBand>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('黄金').last);
    await tester.pumpAndSettle();
    expect((await EnglishLevelProfile.load('guest'))?.band.label, '黄金');
    expect(find.text('黄金'), findsOneWidget);
  });
}
