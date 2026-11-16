import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:chenbot/adaptive.dart';
import 'package:chenbot/batch_store.dart';
import 'package:chenbot/deepseek_recognition.dart';
import 'package:chenbot/dev_recognition.dart';
import 'package:chenbot/english_level.dart';
import 'package:chenbot/english_level_colors.dart';
import 'package:chenbot/recognition_pipeline.dart';
import 'package:chenbot/vocabulary.dart';
import 'package:chenbot/vocabulary_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

DetectedWord word(
  String text, {
  String kind = 'object',
  String lemma = '',
  String reading = '',
  List<String> forms = const [],
}) => DetectedWord(
  kind: kind,
  word: text,
  lemma: lemma,
  forms: forms,
  reading: reading,
  zh: '词',
  definition: 'A description.',
  example: 'An example.',
  exampleZh: '一个例句。',
  box: kind == 'object' ? const [0, 0, 1, 1] : null,
);
Map<String, dynamic> jsonWord(String text, {String kind = 'object'}) => {
  'kind': kind,
  'word': text,
  'lemma': text,
  'forms': <String>[],
  'reading': '',
  'zh': '词',
  'en_definition': 'A description.',
  'example': 'An example.',
  'example_zh': '一个例句。',
  'box': kind == 'object' ? [0, 0, 1, 1] : null,
};
String response(List<Map<String, dynamic>> items) => jsonEncode({
  'choices': [
    {
      'finish_reason': 'stop',
      'message': {
        'content': jsonEncode({'items': items}),
      },
    },
  ],
  'usage': {'prompt_tokens': 10, 'completion_tokens': 3, 'total_tokens': 13},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late BatchStore store;
  late Uint8List image;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('chenbot-vocabulary-test-');
    store = BatchStore(dir);
    image = Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test(
    'offline inflections handle irregular words without merging similar words',
    () async {
      final lexicon = await VocabularyLexicon.load();
      Set<String> en(String w, [String kind = 'object']) =>
          lexicon.aliases(language: 'en', word: w, kind: kind);
      expect(en('BOOKS'), containsAll(['book', 'books', 'booked', 'booking']));
      expect(en('mice'), containsAll(['mouse', 'mice']));
      expect(
        en('happy', 'adjective'),
        containsAll(['happy', 'happier', 'happiest']),
      );
      expect(en('glass'), isNot(contains('class')));
      expect(en('coffee cups'), contains('coffee cup'));
      expect(en('coffee cups'), isNot(contains('cup')));
      final ja = lexicon.aliases(language: 'ja', word: '高い', kind: 'adjective');
      expect(ja, containsAll(['高い', '高くない', '高かった']));
      expect(
        lexicon.aliases(language: 'ja', word: 'いい', kind: 'adjective'),
        isNot(contains('いく')),
      );
      expect(normalizeVocabulary('ネコ', 'ja'), normalizeVocabulary('ねこ', 'ja'));
      expect(
        lexicon.aliases(
          language: 'ja',
          word: '猫',
          kind: 'object',
          modelForms: ['ねこ'],
        ),
        contains('ねこ'),
      );
    },
  );

  test(
    'frequency preference orders without deleting unranked or common results',
    () async {
      final lexicon = await VocabularyLexicon.load();
      final input = [word('book'), word('meticulous'), word('xyzzy-unranked')];
      expect(lexicon.rank('book'), isNotNull);
      expect(lexicon.rank('meticulous'), 17781);
      final basic = lexicon.order(input, Level.h, {});
      final advanced = lexicon.order(input, Level.b, {});
      expect(basic.first.word, 'book');
      expect(advanced.first.word, 'meticulous');
      expect(
        advanced.map((w) => w.word).toSet(),
        input.map((w) => w.word).toSet(),
      );
      final practice = lexicon.order(
        [word('book'), word('meticulous')],
        Level.b,
        {'book': false},
      );
      expect(practice.length, 2);
    },
  );

  test(
    'local table filters to selected or next grade and rejects model lemmas',
    () async {
      var calls = 0;
      final service = DeepSeekRecognition(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            response([
              jsonWord('book'),
              jsonWord('thimble'),
              jsonWord('trellis'),
              {...jsonWord('not-a-real-word-chenbot'), 'lemma': 'book'},
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final result = await recognizeForLearner(
        image: image,
        language: 'en',
        key: 'test-key',
        service: service,
        store: store,
        englishLevel: Level.f,
      );
      expect(result.words.map((w) => w.word), ['thimble', 'trellis']);
      expect(result.words.map((w) => w.frequencyRank), [33971, 46985]);
      expect(calls, 1);
      service.close();
    },
  );

  test(
    'a later candidate can survive when the first eight are filtered',
    () async {
      var calls = 0;
      final service = DeepSeekRecognition(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            response([
              for (var i = 0; i < 8; i++) jsonWord('book'),
              jsonWord('thimble'),
              jsonWord('trellis'),
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final result = await recognizeForLearner(
        image: image,
        language: 'en',
        key: 'test-key',
        service: service,
        store: store,
        englishLevel: Level.f,
      );
      expect(result.words.map((w) => w.word), ['thimble', 'trellis']);
      expect(calls, 1);
      service.close();
    },
  );

  test('deduplicates a word on the same object but keeps distinct objects and names', () async {
    final service = DeepSeekRecognition(
      client: MockClient(
        (_) async => http.Response(
          response([
            {
              ...jsonWord('book'),
              'box': [0, 0, .4, .4],
            },
            {
              ...jsonWord('BOOK'),
              'box': [0, 0, .4, .4],
            },
            {
              ...jsonWord('book'),
              'box': [.6, .6, .9, .9],
            },
            {
              ...jsonWord('cup'),
              'box': [0, 0, .4, .4],
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    final result = await recognizeForLearner(
      image: image,
      language: 'en',
      key: 'test-key',
      service: service,
      store: store,
      englishLevel: Level.h,
    );
    expect(result.words.where((w) => w.word.toLowerCase() == 'book').length, 2);
    expect(result.words.where((w) => w.word == 'cup').length, 1);
    service.close();
  });

  test(
    'level mismatch retries once with local ranks and keeps strict filtering',
    () async {
      final prompts = <String>[];
      var usage = 0;
      final service = DeepSeekRecognition(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          prompts.add(body['messages'][0]['content'][0]['text'] as String);
          return http.Response(
            response(
              prompts.length == 1
                  ? [jsonWord('book'), jsonWord('not-a-real-word-chenbot')]
                  : [
                      jsonWord('book'),
                      jsonWord('thimble'),
                      jsonWord('not-a-real-word-chenbot'),
                    ],
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
        onUsage: (_) async {
          usage++;
        },
      );
      final result = await recognizeForLearner(
        image: image,
        language: 'en',
        key: 'test-key',
        service: service,
        store: store,
        englishLevel: Level.f,
      );
      expect(result.words.map((word) => word.word), ['thimble']);
      expect(result.requestCount, 2);
      expect(usage, 2);
      expect(prompts.first, isNot(contains('local frequency filter')));
      expect(prompts.last, contains('10000–74999'));
      expect(prompts.last, contains('"book":572'));
      expect(prompts.last, contains('"not-a-real-word-chenbot":null'));
      expect(prompts.last, contains('guess an object just to fit the range'));
      service.close();
    },
  );

  test(
    'level mismatch with no later match stops after one level retry',
    () async {
      var calls = 0;
      final service = DeepSeekRecognition(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            response([jsonWord('book'), jsonWord('not-a-real-word-chenbot')]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final result = await recognizeForLearner(
        image: image,
        language: 'en',
        key: 'test-key',
        service: service,
        store: store,
        englishLevel: Level.f,
      );
      expect(result.words, isEmpty);
      expect(result.noMatchingWords, isTrue);
      expect(result.requestCount, 2);
      expect(calls, 2);
      service.close();
    },
  );

  test(
    'an empty level retry reports a level mismatch, not no visible object',
    () async {
      var calls = 0;
      final service = DeepSeekRecognition(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            response(calls == 1 ? [jsonWord('book')] : []),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final result = await recognizeForLearner(
        image: image,
        language: 'en',
        key: 'test-key',
        service: service,
        store: store,
        englishLevel: Level.f,
      );
      expect(result.noMatchingWords, isTrue);
      expect(result.noVisibleObject, isFalse);
      expect(calls, 2);
      service.close();
    },
  );

  test('level and trash retries share a three-request budget', () async {
    final photo = await store.addPhoto(image, 'en');
    await store.saveResults(photo, [word('cat')]);
    await store.discard((await store.cards()).single['id'] as String);
    var calls = 0;
    final prompts = <String>[];
    final service = DeepSeekRecognition(
      client: MockClient((request) async {
        calls++;
        final body = jsonDecode(request.body) as Map;
        prompts.add(body['messages'][0]['content'][0]['text'] as String);
        final values = [jsonWord('book'), jsonWord('cat'), jsonWord('thimble')];
        return http.Response(
          response([values[calls - 1]]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final result = await recognizeForLearner(
      image: image,
      language: 'en',
      key: 'test-key',
      service: service,
      store: store,
      englishLevel: Level.f,
    );
    expect(result.words.single.word, 'thimble');
    expect(result.requestCount, 3);
    expect(calls, 3);
    expect(prompts.last, contains('"book":572'));
    expect(prompts.last, contains('cat'));
    expect(prompts.last, contains('10000–74999'));
    service.close();
  });

  test('retry feedback does not leak into the next image', () async {
    final prompts = <String>[];
    final service = DeepSeekRecognition(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        prompts.add(body['messages'][0]['content'][0]['text'] as String);
        return http.Response(
          response([jsonWord(prompts.length == 3 ? 'thimble' : 'book')]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    await recognizeForLearner(
      image: image,
      language: 'en',
      key: 'test-key',
      service: service,
      store: store,
      englishLevel: Level.f,
    );
    await recognizeForLearner(
      image: image,
      language: 'en',
      key: 'test-key',
      service: service,
      store: store,
      englishLevel: Level.f,
    );
    expect(prompts.length, 3);
    expect(prompts[1], contains('local frequency filter'));
    expect(prompts[2], isNot(contains('local frequency filter')));
    expect(prompts[2], isNot(contains('previous result')));
    service.close();
  });

  test(
    'level retry gives the correct local rank range for every grade',
    () async {
      final prompts = <String>[];
      final service = DeepSeekRecognition(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          prompts.add(body['messages'][0]['content'][0]['text'] as String);
          return http.Response(
            response([jsonWord('not-a-real-word-chenbot')]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final ranges = <Level, String>{
        Level.h: '1–39999',
        Level.f: '10000–74999',
        Level.d: '40000–99999',
        Level.c: '75000–149999',
        Level.b: '100000–249999',
        Level.a: '150000–500000',
        Level.s: '250000–500000',
      };
      for (final entry in ranges.entries) {
        final outcome = await recognizeForLearner(
          image: image,
          language: 'en',
          key: 'test-key',
          service: service,
          store: store,
          englishLevel: entry.key,
        );
        expect(outcome.requestCount, 2);
        expect(outcome.noMatchingWords, isTrue);
        expect(prompts.last, contains(entry.value));
      }
      expect(prompts.length, ranges.length * 2);
      service.close();
    },
  );

  test('no further level retry happens after two trash retries', () async {
    final photo = await store.addPhoto(image, 'en');
    await store.saveResults(photo, [word('cat')]);
    await store.discard((await store.cards()).single['id'] as String);
    var calls = 0;
    final service = DeepSeekRecognition(
      client: MockClient((_) async {
        calls++;
        return http.Response(
          response([jsonWord(calls < 3 ? 'cat' : 'book')]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final outcome = await recognizeForLearner(
      image: image,
      language: 'en',
      key: 'test-key',
      service: service,
      store: store,
      englishLevel: Level.f,
    );
    expect(calls, 3);
    expect(outcome.requestCount, 3);
    expect(outcome.noMatchingWords, isTrue);
    service.close();
  });

  test('English requires a selected grade before making a request', () async {
    var calls = 0;
    final service = DeepSeekRecognition(
      client: MockClient((_) async {
        calls++;
        return http.Response(response([jsonWord('book')]), 200);
      }),
    );
    await expectLater(
      recognizeForLearner(
        image: image,
        language: 'en',
        key: 'test-key',
        service: service,
        store: store,
      ),
      throwsA(isA<DeepSeekException>()),
    );
    expect(calls, 0);
    service.close();
  });

  test(
    'Japanese recognition does not use the English frequency table',
    () async {
      final service = DeepSeekRecognition(
        client: MockClient(
          (_) async => http.Response(
            response([jsonWord('猫')]),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      final result = await recognizeForLearner(
        image: image,
        language: 'ja',
        key: 'test-key',
        service: service,
        store: store,
      );
      expect(result.words.single.word, '猫');
      service.close();
    },
  );

  test(
    'Shakespeare band has local coverage and unlisted old cards stay saved',
    () async {
      final lexicon = await VocabularyLexicon.load();
      expect(lexicon.rank('reticle'), 298618);
      final accepted = lexicon.filterEnglishDifficulty([
        word('reticle'),
        word('not-a-real-word-chenbot'),
      ], chenbotBands.last);
      expect(accepted.map((w) => w.word), ['reticle']);
      final photo = await store.addPhoto(image, 'en');
      await store.saveResults(photo, [word('not-a-real-word-chenbot')]);
      expect((await store.cards()).single['word'], 'not-a-real-word-chenbot');
      expect(await store.visibleCards(), isEmpty);
    },
  );

  test(
    'a dragged label position is saved without overwriting card data',
    () async {
      final photo = await store.addPhoto(image, 'en');
      await store.saveResults(photo, [word('book')]);
      final id = (await store.cards()).single['id'] as String;
      await store.moveLabel(id, .3, .7);
      final reopened = (await BatchStore(dir).cards()).single;
      expect(reopened['word'], 'book');
      expect(reopened['labelX'], .3);
      expect(reopened['labelY'], .7);
      await expectLater(store.moveLabel(id, -1, .2), throwsFormatException);
      expect((await store.cards()).single['labelX'], .3);
    },
  );

  test('word colors follow the seven locally checked grades', () {
    Color? color(int rank) =>
        englishWordColor({'language': 'en', 'frequencyRank': rank});
    expect(color(1), Colors.white);
    expect(color(10000), const Color(0xffd8efc9));
    expect(color(40000), const Color(0xffe9c6a8));
    expect(color(75000), const Color(0xffd8dadd));
    expect(color(100000), const Color(0xffffd76a));
    expect(color(150000), const Color(0xffd6efff));
    expect(color(250000), const Color(0xffff00ff));
    expect(wordTextColor(color(250000)), Colors.black);
    expect(englishWordColor({'language': 'en'}), isNull);
    expect(
      englishWordColor({'language': 'ja', 'frequencyRank': 250000}),
      isNull,
    );
  });

  test(
    'trash persists, filters other photos and forms, and restores favorites',
    () async {
      final photo = await store.addPhoto(image, 'en');
      await store.saveResults(photo, [word('cat'), word('dog')]);
      final cat = (await store.cards()).first;
      await store.favorite(cat);
      await store.discard(cat['id'] as String);
      expect(
        (await BatchStore(dir).trash()).single['aliases'],
        contains('cats'),
      );
      expect((await store.visibleCards()).map((x) => x['word']), ['dog']);
      expect(await store.visibleFavorites(), isEmpty);
      expect((await store.favorites()).single['word'], 'cat');
      final next = await store.addPhoto(image, 'en');
      await store.saveResults(next, [word('cats'), word('bird')]);
      expect((await store.visibleCards()).map((x) => x['word']), [
        'dog',
        'bird',
      ]);
      final japanese = await store.addPhoto(image, 'ja');
      await store.saveResults(japanese, [word('cat')]);
      expect(
        (await store.visibleCards())
            .where((x) => x['language'] == 'ja')
            .single['word'],
        'cat',
      );
      final id = (await store.trash()).single['id'] as String;
      await store.restore(id);
      expect((await store.visibleFavorites()).single['word'], 'cat');
      expect(
        (await store.visibleCards()).map((x) => x['word']),
        contains('cat'),
      );
      expect(await store.trash(), isEmpty);
    },
  );

  test('old discarded cards migrate and can be restored', () async {
    await dir.create(recursive: true);
    await File('${dir.path}/cards.json').writeAsString(
      jsonEncode([
        {
          'id': 'old',
          'language': 'en',
          'word': 'book',
          'kind': 'object',
          'discarded': true,
        },
      ]),
    );
    final entry = (await store.trash()).single;
    expect(entry['aliases'], contains('books'));
    await store.restore(entry['id'] as String);
    expect((await store.cards()).single['discarded'], false);
    expect(await store.trash(), isEmpty);
  });

  test(
    'manual and newly observed Japanese forms are saved for later filtering',
    () async {
      final photo = await store.addPhoto(image, 'ja');
      await store.saveResults(photo, [word('猫')]);
      await store.discard((await store.cards()).single['id'] as String);
      final id = (await store.trash()).single['id'] as String;
      await store.addTrashAlias(id, 'ネコ');
      final allowed = await store.filterWords([
        word('ねこ', forms: ['ネコちゃん']),
      ], 'ja');
      expect(allowed, isEmpty);
      expect(
        (await BatchStore(dir).trash()).single['aliases'],
        contains('ねこちゃん'),
      );
      expect(await store.filterWords([word('ネコちゃん')], 'ja'), isEmpty);
    },
  );

  test(
    'all suppressed nouns trigger up to two retries for a different noun',
    () async {
      final photo = await store.addPhoto(image, 'en');
      await store.saveResults(photo, [word('cat')]);
      await store.discard((await store.cards()).single['id'] as String);
      final prompts = <String>[];
      var usage = 0;
      final service = DeepSeekRecognition(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          prompts.add(body['messages'][0]['content'][0]['text'] as String);
          final values = [jsonWord('cat'), jsonWord('cats'), jsonWord('tree')];
          return http.Response(
            response([values[prompts.length - 1]]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
        onUsage: (_) async {
          usage++;
        },
      );
      final outcome = await recognizeForLearner(
        image: image,
        language: 'en',
        englishLevel: Level.h,
        key: 'test-key',
        service: service,
        store: store,
      );
      expect(outcome.requestCount, 3);
      expect(outcome.words.single.word, 'tree');
      expect(outcome.words.single.kind, 'object');
      expect(usage, 3);
      expect(prompts.first, isNot(contains('previous result')));
      expect(prompts[1], contains('cat'));
      expect(prompts[2], contains('cats'));
      service.close();
    },
  );

  test(
    'partial match does not retry; total exhaustion stops after three calls',
    () async {
      final photo = await store.addPhoto(image, 'en');
      await store.saveResults(photo, [word('cat')]);
      await store.discard((await store.cards()).single['id'] as String);
      var calls = 0;
      final mixed = DeepSeekRecognition(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            response([jsonWord('cat'), jsonWord('dog')]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final result = await recognizeForLearner(
        image: image,
        language: 'en',
        englishLevel: Level.h,
        key: 'test-key',
        service: mixed,
        store: store,
      );
      expect(calls, 1);
      expect(result.words.single.word, 'dog');
      mixed.close();
      calls = 0;
      final repeating = DeepSeekRecognition(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            response([jsonWord('cats')]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final exhausted = await recognizeForLearner(
        image: image,
        language: 'en',
        englishLevel: Level.h,
        key: 'test-key',
        service: repeating,
        store: store,
      );
      expect(calls, 3);
      expect(exhausted.exhausted, isTrue);
      repeating.close();
    },
  );

  test('empty results and adjectives do not become photo labels', () async {
    var calls = 0;
    final service = DeepSeekRecognition(
      client: MockClient((request) async {
        calls++;
        final body = jsonDecode(request.body) as Map;
        expect(body['messages'][0]['content'][0]['text'], contains('noun'));
        return http.Response(
          response([
            jsonWord('bright', kind: 'adjective'),
            jsonWord(
              'beautiful',
            ), // Model incorrectly labels an adjective as an object.
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final result = await recognizeForLearner(
      image: image,
      language: 'en',
      englishLevel: Level.h,
      key: 'test-key',
      service: service,
      store: store,
    );
    expect(result.words, isEmpty);
    expect(result.noVisibleObject, isTrue);
    expect(calls, 1);
    service.close();
  });

  test('empty noun list ends a retry after a filtered result', () async {
    final photo = await store.addPhoto(image, 'en');
    await store.saveResults(photo, [word('cat')]);
    await store.discard((await store.cards()).single['id'] as String);
    var calls = 0;
    final service = DeepSeekRecognition(
      client: MockClient((_) async {
        calls++;
        return http.Response(
          response(calls == 1 ? [jsonWord('cat')] : []),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final result = await recognizeForLearner(
      image: image,
      language: 'en',
      englishLevel: Level.h,
      key: 'test-key',
      service: service,
      store: store,
    );
    expect(result.exhausted, isTrue);
    expect(result.noVisibleObject, isFalse);
    expect(calls, 2);
    service.close();
  });

  test('Japanese readings catch kana without conflating different kanji homophones', () async {
    final photo = await store.addPhoto(image, 'ja');
    await store.saveResults(photo, [word('花', reading: 'はな')]);
    await store.discard((await store.cards()).single['id'] as String);
    expect(await store.filterWords([word('ハナ')], 'ja'), isEmpty);
    final differentKanji = word('鼻', reading: 'はな', lemma: 'はな', forms: ['はな']);
    expect((await store.filterWords([differentKanji], 'ja')).single.word, '鼻');
  });

  test('12-question reference range follows a simulated rank cutoff', () {
    int totalIndex(int cutoff) {
      var total = 0;
      for (var seed = 0; seed < 25; seed++) {
        final session = AdaptiveEnglishSession(random: Random(seed));
        for (var n = 0; n < 12; n++) {
          final q = session.next();
          session.answer(q.frequencyRank <= cutoff);
        }
        total +=
            chenbotBands.indexOf(session.result.lower) +
            chenbotBands.indexOf(session.result.upper);
      }
      return total;
    }

    expect(totalIndex(20000), greaterThan(totalIndex(5000)));
    expect(totalIndex(20000), lessThan(totalIndex(100000)));
    // This simulation checks monotonicity only, not real learner accuracy.
  });

  testWidgets('word tag saves on tap and supports dragging into trash', (
    tester,
  ) async {
    var saved = 0;
    final dropped = <Map<String, dynamic>>[];
    final card = <String, dynamic>{'word': 'book'};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              VocabularyTag(card: card, onFavorite: () => saved++),
              const SizedBox(height: 100),
              TrashDropTarget(onDiscard: dropped.add),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('book'));
    expect(saved, 1);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('book')),
    );
    await gesture.moveTo(tester.getCenter(find.byType(TrashDropTarget)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(dropped.single['word'], 'book');
  });

  testWidgets(
    'photo label moves immediately with a tether and persists its position',
    (tester) async {
      final card = <String, dynamic>{
        'id': 'card-1',
        'word': 'book',
        'language': 'en',
        'frequencyRank': 572,
        'box': [.6, .6, .8, .8],
      };
      Offset? savedPosition;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                child: VocabularyPhotoCanvas(
                  image: const ColoredBox(color: Colors.blue),
                  aspectRatio: 4 / 3,
                  minHeight: 240,
                  maxHeight: 240,
                  cards: [card],
                  onFavorite: (_) {},
                  onPositionChanged: (_, position) => savedPosition = position,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initial = tester.getTopLeft(find.byType(VocabularyTag));
      final start = tester.getCenter(find.text('book'));
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(-55, -50));
      await tester.pump();
      final linePainters = find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.painter.runtimeType.toString() == '_WordLinesPainter',
      );
      expect(linePainters, findsNWidgets(2));
      final dynamic overlayPainter = tester
          .widget<CustomPaint>(linePainters.last)
          .painter;
      final (Offset, Offset) line = (overlayPainter.lines as List).single;
      expect(line.$2.dx, closeTo(start.dx - 55, .1));
      expect(line.$2.dy, closeTo(start.dy - 50, .1));
      expect((overlayPainter.cutout as Rect).contains(line.$2), isTrue);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(savedPosition, isNotNull);
      final moved = tester.getTopLeft(find.byType(VocabularyTag));
      expect(moved.dx, lessThan(initial.dx));
      expect(moved.dy, lessThan(initial.dy));
      expect(linePainters, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dragging a word does not swipe the surrounding card', (
    tester,
  ) async {
    var pageSwipes = 0;
    final card = <String, dynamic>{
      'id': 'one',
      'word': 'book',
      'language': 'en',
      'frequencyRank': 572,
      'box': [.1, .1, .25, .25],
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: GestureDetector(
              onHorizontalDragEnd: (_) => pageSwipes++,
              child: SizedBox(
                width: 320,
                child: VocabularyPhotoCanvas(
                  image: const ColoredBox(color: Colors.blue),
                  aspectRatio: 4 / 3,
                  minHeight: 240,
                  maxHeight: 240,
                  cards: [card],
                  onFavorite: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initial = tester.getTopLeft(find.byType(VocabularyTag));
    final wordDrag = await tester.startGesture(
      tester.getCenter(find.text('book')),
    );
    await wordDrag.moveBy(const Offset(80, 0));
    await tester.pump();
    await wordDrag.up();
    await tester.pumpAndSettle();
    expect(pageSwipes, 0);
    expect(
      tester.getTopLeft(find.byType(VocabularyTag)).dx,
      greaterThan(initial.dx),
    );
    final canvas = tester.getTopLeft(find.byType(VocabularyPhotoCanvas));
    final backgroundDrag = await tester.startGesture(
      canvas + const Offset(20, 200),
    );
    await backgroundDrag.moveBy(const Offset(80, 0));
    await tester.pump();
    await backgroundDrag.up();
    await tester.pumpAndSettle();
    expect(pageSwipes, 1);
  });

  testWidgets('different names for one object remain separately visible', (
    tester,
  ) async {
    final cards = [
      for (final word in ['cup', 'mug', 'beaker'])
        <String, dynamic>{
          'id': word,
          'word': word,
          'language': 'en',
          'box': [.4, .35, .7, .7],
        },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: VocabularyPhotoCanvas(
                image: const ColoredBox(color: Colors.blue),
                aspectRatio: 4 / 3,
                minHeight: 240,
                maxHeight: 240,
                cards: cards,
                onFavorite: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final positions = [
      for (final word in ['cup', 'mug', 'beaker'])
        tester.getRect(
          find.ancestor(
            of: find.text(word),
            matching: find.byType(VocabularyTag),
          ),
        ),
    ];
    expect(positions[0].overlaps(positions[1]), isFalse);
    expect(positions[0].overlaps(positions[2]), isFalse);
    expect(positions[1].overlaps(positions[2]), isFalse);
  });

  testWidgets('long image labels wrap without ellipsis and remain draggable', (
    tester,
  ) async {
    const longWord = 'pneumonoultramicroscopicsilicovolcanoconiosis';
    final card = <String, dynamic>{'word': longWord};
    final dropped = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                width: 320,
                height: 180,
                child: Stack(
                  children: [
                    PositionedVocabularyTag(
                      card: card,
                      box: const [.95, .85, 1, 1],
                      photoSize: const Size(320, 180),
                      onFavorite: () {},
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 80),
              TrashDropTarget(onDiscard: dropped.add),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final label = tester.widget<Text>(find.text(longWord));
    expect(label.data, longWord);
    expect(label.overflow, isNot(TextOverflow.ellipsis));
    expect(tester.getSize(find.text(longWord)).height, greaterThan(20));
    final labelRect = tester.getRect(find.text(longWord));
    expect(labelRect.right, lessThanOrEqualTo(320));
    expect(labelRect.bottom, lessThanOrEqualTo(180));
    expect(tester.takeException(), isNull);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text(longWord)),
    );
    await gesture.moveTo(tester.getCenter(find.byType(TrashDropTarget)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(dropped.single['word'], longWord);
    expect(tester.takeException(), isNull);
  });

  testWidgets('panoramic and tall photos keep full labels draggable', (
    tester,
  ) async {
    const longWord = 'pneumonoultramicroscopicsilicovolcanoconiosis';
    for (final dimensions in [(400, 10), (10, 400)]) {
      final card = <String, dynamic>{
        'word': longWord,
        'box': [.9, .9, 1, 1],
      };
      final dropped = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  width: 320,
                  child: VocabularyPhotoCanvas(
                    image: const ColoredBox(color: Colors.blue),
                    aspectRatio: dimensions.$1 / dimensions.$2,
                    minHeight: 260,
                    maxHeight: 260,
                    cards: [card],
                    onFavorite: (_) {},
                  ),
                ),
                TrashDropTarget(onDiscard: dropped.add),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(longWord), findsOneWidget);
      expect(tester.takeException(), isNull);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(longWord)),
      );
      await gesture.moveTo(tester.getCenter(find.byType(TrashDropTarget)));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(dropped.single['word'], longWord);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });
}
