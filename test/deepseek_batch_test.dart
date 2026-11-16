import 'dart:io';
import 'dart:typed_data';

import 'package:chenbot/batch_page.dart';
import 'package:chenbot/batch_store.dart';
import 'package:chenbot/deepseek_recognition.dart';
import 'package:chenbot/dev_recognition.dart';
import 'package:chenbot/english_level.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StubRecognition extends DeepSeekRecognition {
  StubRecognition(this.onRecognize);
  final void Function() onRecognize;

  @override
  Future<List<DetectedWord>> recognize(
    Uint8List bytes,
    String language,
    String key,
  ) async {
    onRecognize();
    return [
      DetectedWord.fromJson({
        'kind': 'object',
        'word': 'book',
        'reading': '',
        'zh': '书',
        'en_definition': 'A book.',
        'example': 'A book is here.',
        'example_zh': '这里有一本书。',
        'box': [0, 0, 1, 1],
      }),
    ];
  }
}

class FailingRecognition extends DeepSeekRecognition {
  FailingRecognition(this.onRecognize);
  final void Function() onRecognize;

  @override
  Future<List<DetectedWord>> recognize(
    Uint8List bytes,
    String language,
    String key,
  ) async {
    onRecognize();
    throw const DeepSeekException('DeepSeek 账户余额不足，请充值后再试。');
  }
}

class QueueStore extends BatchStore {
  QueueStore(super.root);
  final photo = <String, dynamic>{
    'id': 'p1',
    'file': 'test.jpg',
    'status': 'queued',
    'language': 'en',
  };
  final saved = <DetectedWord>[];
  final additional = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> photos() async => [photo, ...additional];
  @override
  Future<List<Map<String, dynamic>>> cards() async => [];
  @override
  Future<List<Map<String, dynamic>>> favorites() async => [];
  @override
  Future<List<Map<String, dynamic>>> trash() async => [];
  @override
  Future<List<DetectedWord>> filterWords(
    List<DetectedWord> words,
    String language,
  ) async => words;
  @override
  Future<Uint8List> readPhoto(Map<String, dynamic> photo) async =>
      Uint8List.fromList([0xff, 0xd8, 0xff, 1]);
  @override
  Future<void> saveResults(
    Map<String, dynamic> photo,
    List<DetectedWord> words,
  ) async {
    saved.addAll(words);
    photo['status'] = words.isEmpty ? 'no_match' : 'processed';
  }

  @override
  Future<void> setStatus(String id, String status) async {
    [photo, ...additional].firstWhere((item) => item['id'] == id)['status'] =
        status;
  }
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({
      'english_level_v4_guest': 'chenbot:h',
    });
  });

  testWidgets('batch upload starts only after confirmation and stores result', (
    tester,
  ) async {
    final store = QueueStore(Directory('/unused'));
    await DeepSeekKeyStore('guest').save('test-key');
    var requests = 0;
    DeepSeekRecognition service() => StubRecognition(() => requests++);
    await tester.pumpWidget(
      MaterialApp(
        home: BatchPage(
          japanese: false,
          storeOverride: store,
          serviceFactory: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('处理待识别照片'));
    await tester.pumpAndSettle();
    expect(find.text('发送照片到 DeepSeek？'), findsOneWidget);
    expect(requests, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(store.photo['status'], 'queued');

    await tester.tap(find.text('处理待识别照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 10 && store.saved.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(requests, 1);
    expect(store.photo['status'], 'processed');
    expect(store.saved.single.word, 'book');
  });

  testWidgets('batch requires a selected grade before requesting upload', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = QueueStore(Directory('/unused'));
    await DeepSeekKeyStore('guest').save('test-key');
    var requests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: BatchPage(
          japanese: false,
          storeOverride: store,
          serviceFactory: () => StubRecognition(() => requests++),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('处理待识别照片'));
    await tester.pumpAndSettle();
    expect(find.text('请先选择英语识图等级。'), findsOneWidget);
    expect(find.text('发送照片到 DeepSeek？'), findsNothing);
    expect(requests, 0);
  });

  testWidgets('a filtered photo can be retried after changing the grade', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'english_level_v4_guest': 'chenbot:f',
    });
    final store = QueueStore(Directory('/unused'));
    await DeepSeekKeyStore('guest').save('test-key');
    var requests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: BatchPage(
          japanese: false,
          storeOverride: store,
          serviceFactory: () => StubRecognition(() => requests++),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('处理待识别照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 30 && store.photo['status'] == 'queued'; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(requests, 2);
    expect(store.photo['status'], 'no_match');
    expect(store.saved, isEmpty);
    await tester.tap(find.byType(DropdownButton<EnglishBand>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文盲').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('处理待识别照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 30 && store.photo['status'] == 'no_match'; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(requests, 3);
    expect(store.photo['status'], 'processed');
    expect(store.saved.single.word, 'book');
  });

  testWidgets(
    'batch pauses on a provider error without submitting remaining photos',
    (tester) async {
      final store = QueueStore(Directory('/unused'));
      store.additional.add({
        'id': 'p2',
        'file': 'test2.jpg',
        'status': 'queued',
        'language': 'en',
      });
      await DeepSeekKeyStore('guest').save('test-key');
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: BatchPage(
            japanese: false,
            storeOverride: store,
            serviceFactory: () => FailingRecognition(() => attempts++),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 20 && find.text('处理待识别照片').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.text('处理待识别照片'));
      await tester.pumpAndSettle();
      expect(find.textContaining('将从这台设备把 2 张照片'), findsOneWidget);
      await tester.tap(find.text('确认发送'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 30 && attempts == 0; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(attempts, 1);
      expect(store.photo['status'], 'failed');
      expect(store.additional.single['status'], 'queued');
      expect(find.textContaining('余额不足'), findsOneWidget);
    },
  );
}
