import 'package:chenbot/reader_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pressWord(
  WidgetTester tester,
  Finder paragraph,
  int start,
  int end,
) async {
  await tester.scrollUntilVisible(
    paragraph,
    250,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.ensureVisible(paragraph);
  await tester.pumpAndSettle();
  final text = find.descendant(of: paragraph, matching: find.byType(RichText));
  final render = tester.renderObject<RenderParagraph>(text);
  final box = render
      .getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end))
      .first;
  await tester.longPressAt(render.localToGlobal(box.toRect().center));
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every article word has a local Chinese meaning, including names and possessives', () async {
    final treaty = await loadReadingArticle(readingArticles.first);
    final speech = await loadReadingArticle(readingArticles.last);
    for (var n = 1; n <= 13; n++) {
      expect(treaty, contains('Article $n.'));
    }
    expect(treaty.last, 'VICTORIA R.');
    expect(speech.length, 8);
    expect(speech.first, contains('ordained'));
    expect(speech.last, contains('forever mankind'));

    final words = <String>{};
    for (final paragraph in [...treaty, ...speech]) {
      words.addAll(
        readingWordPattern
            .allMatches(paragraph)
            .map((match) => match.group(0)!),
      );
    }
    for (final article in readingArticles) {
      words.addAll(
        readingWordPattern
            .allMatches(article.englishTitle)
            .map((match) => match.group(0)!),
      );
    }
    for (final word in words) {
      final entry = await ReadingDictionary.lookup(word);
      expect(entry, isNotNull, reason: word);
      expect(entry!.chinese, isNotEmpty, reason: word);
      expect(entry.english, isNotEmpty, reason: word);
    }
    expect((await ReadingDictionary.lookup('Keying'))!.chinese, contains('耆英'));
    expect(
      (await ReadingDictionary.lookup('Aldrin'))!.chinese,
      contains('奥尔德林'),
    );
    expect(
      (await ReadingDictionary.lookup('Armstrong'))!.chinese,
      contains('阿姆斯特朗'),
    );
    expect((await ReadingDictionary.lookup('Canton'))!.chinese, contains('广州'));
    expect(
      (await ReadingDictionary.lookup('Pottinger'))!.chinese,
      contains('璞鼎查'),
    );
    expect((await ReadingDictionary.lookup('30th'))!.chinese, contains('第 30'));
    expect((await ReadingDictionary.lookup('c'))!.chinese, contains('等等'));
    expect(
      (await ReadingDictionary.lookup("mankind's"))!.chinese,
      contains('所有格'),
    );
  });

  test(
    'every selectable word has a full source or supplemental example',
    () async {
      for (final article in readingArticles) {
        final paragraphs = await loadReadingArticle(article);
        final words = <String>{};
        for (final text in [article.englishTitle, ...paragraphs]) {
          words.addAll(
            readingWordPattern.allMatches(text).map((match) => match.group(0)!),
          );
        }
        for (final word in words) {
          final fromSource = readingExampleForWord(word, '', paragraphs);
          final entry = await ReadingDictionary.lookup(word);
          expect(
            isReadingSentence(fromSource) || isReadingSentence(entry!.example),
            isTrue,
            reason: '${article.id}: $word',
          );
        }
      }
    },
  );

  testWidgets(
    'shelf opens the full speech and a word long press shows its meaning and example',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ReaderShelf())),
      );
      await tester.pumpAndSettle();
      expect(find.text('南京条约'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('假如登月失败'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(find.text('假如登月失败'));
      await tester.pumpAndSettle();
      expect(find.text('假如登月失败'), findsOneWidget);
      await tester.tap(find.text('假如登月失败'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ArticleReaderPage), findsOneWidget);
      expect(readingArticles.last.description, contains('讲话从未发表'));
      final first = find.byWidgetPredicate(
        (w) => w is ReaderParagraph && w.text.startsWith('Fate has ordained'),
      );
      await pressWord(tester, first, 0, 4);
      expect(find.text('Fate'), findsOneWidget);
      expect(find.text('词义'), findsOneWidget);
      expect(find.textContaining('命运'), findsOneWidget);
      expect(find.text('原文例句'), findsOneWidget);
      expect(find.textContaining('Fate has ordained'), findsWidgets);
    },
  );

  testWidgets('treaty final abbreviation opens its historical definition', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ReaderShelf())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('南京条约'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    final last = find.byWidgetPredicate(
      (w) => w is ReaderParagraph && w.text == 'VICTORIA R.',
    );
    await pressWord(tester, last, 9, 10);
    expect(find.text('R'), findsOneWidget);
    expect(find.textContaining('Regina'), findsWidgets);
    expect(find.text('补充例句'), findsOneWidget);
  });

  testWidgets('English article titles support the same word lookup', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: ArticleReaderPage(article: readingArticles.last)),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    final title = find.byWidgetPredicate(
      (w) => w is ReaderParagraph && w.text == 'In Event of Moon Disaster',
    );
    await pressWord(tester, title, 3, 8);
    expect(find.text('Event'), findsOneWidget);
    expect(find.textContaining('事件'), findsOneWidget);
    expect(find.text('补充例句'), findsOneWidget);
  });
}
