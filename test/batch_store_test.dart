import 'dart:io';
import 'dart:typed_data';

import 'package:chenbot/batch_store.dart';
import 'package:chenbot/dev_recognition.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  late Directory dir;
  late BatchStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chenbot-test-');
    store = BatchStore(dir);
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  test('photo, cards, favorites and discard persist separately', () async {
    final photo = await store.addPhoto(
      Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4))),
      'en',
    );
    final word = DetectedWord(
      kind: 'object',
      word: 'cat',
      reading: '',
      zh: '猫',
      definition: 'An animal.',
      example: 'A cat sleeps.',
      exampleZh: '猫在睡觉。',
      box: [.1, .1, .8, .8],
    );
    await store.saveResults(photo, [word]);
    final cards = await store.cards();
    expect((await store.photos()).single['status'], 'processed');
    await store.favorite(cards.single);
    await store.favorite(cards.single);
    expect((await store.favorites()).length, 1);
    await store.discard(cards.single['id'] as String);
    expect((await store.cards()).single['discarded'], isTrue);
    expect((await store.favorites()).single['word'], 'cat');
    expect(await File('${dir.path}/${photo['file']}').exists(), isTrue);
  });
  test('concurrent favorites do not overwrite each other', () async {
    Map<String, dynamic> entry(String value) => {
      'language': 'en',
      'word': value,
      'reading': '',
      'zh': '词',
      'en_definition': 'definition',
      'example': 'example',
      'example_zh': '例句',
    };
    await Future.wait([
      store.favorite(entry('cat')),
      store.favorite(entry('dog')),
      store.favorite(entry('bird')),
    ]);
    expect((await store.favorites()).map((e) => e['word']).toSet(), {
      'cat',
      'dog',
      'bird',
    });
  });
  test('local storage scopes keep accounts separate and reject paths', () {
    expect(localScopeForUser(null), 'guest');
    expect(
      localScopeForUser('12345678-1234-1234-1234-123456789abc'),
      '12345678-1234-1234-1234-123456789abc',
    );
    expect(() => localScopeForUser('../guest'), throwsFormatException);
  });
  test('invalid image is rejected without creating a record', () async {
    await expectLater(
      store.addPhoto(Uint8List.fromList([1, 2, 3]), 'en'),
      throwsFormatException,
    );
    expect(await store.photos(), isEmpty);
  });
}
