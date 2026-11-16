import 'dart:io';

import 'package:chenbot/batch_page.dart';
import 'package:chenbot/batch_store.dart';
import 'package:chenbot/english_level.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeStore extends BatchStore {
  FakeStore() : super(Directory('/nonexistent'));
  final rows = <Map<String, dynamic>>[
    {
      'id': 'a',
      'photoId': 'p',
      'file': 'missing.jpg',
      'language': 'en',
      'kind': 'object',
      'word': 'cat',
      'reading': '',
      'zh': '猫',
      'en_definition': 'animal',
      'example': 'A cat',
      'example_zh': '一只猫',
      'box': [0, 0, 1, 1],
      'discarded': false,
    },
    {
      'id': 'b',
      'photoId': 'p',
      'file': 'missing.jpg',
      'language': 'en',
      'kind': 'object',
      'word': 'dog',
      'reading': '',
      'zh': '狗',
      'en_definition': 'animal',
      'example': 'A dog',
      'example_zh': '一只狗',
      'box': [0, 0, 1, 1],
      'discarded': false,
    },
  ];
  final starred = <Map<String, dynamic>>[];
  @override
  Future<List<Map<String, dynamic>>> photos() async => [];
  @override
  Future<List<Map<String, dynamic>>> cards() async => rows;
  @override
  Future<List<Map<String, dynamic>>> favorites() async => starred;
  @override
  Future<List<Map<String, dynamic>>> trash() async => [];
  @override
  Future<void> favorite(Map<String, dynamic> card) async {
    starred.add(Map.of(card));
  }

  @override
  Future<void> discard(String id) async {
    rows.firstWhere((c) => c['id'] == id)['discarded'] = true;
  }
}

void main() {
  testWidgets('swipe next, save a word, then discard its card', (tester) async {
    SharedPreferences.setMockInitialValues({
      'english_level_v4_guest': 'chenbot:h',
    });
    final store = FakeStore();
    await tester.pumpWidget(
      MaterialApp(home: BatchPage(japanese: false, storeOverride: store)),
    );
    await tester.pumpAndSettle();
    expect(find.text('cat'), findsOneWidget);
    expect(find.text('AI 生成内容，仅供学习参考'), findsOneWidget);
    await tester.fling(
      find.byType(SingleChildScrollView).first,
      const Offset(-300, 0),
      1200,
    );
    await tester.pump();
    expect(find.text('dog'), findsOneWidget);
    await tester.fling(
      find.byType(SingleChildScrollView).first,
      const Offset(300, 0),
      1200,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏单词'));
    await tester.pumpAndSettle();
    expect(store.starred.single['word'], 'dog');
    await tester.fling(
      find.byType(SingleChildScrollView).first,
      const Offset(300, 0),
      1200,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard · 移出卡片流'));
    await tester.pumpAndSettle();
    expect(store.rows.last['discarded'], isTrue);
  });

  testWidgets('changing the grade filters old cards without deleting them', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'english_level_v4_guest': 'chenbot:h',
    });
    final store = FakeStore();
    await tester.pumpWidget(
      MaterialApp(home: BatchPage(japanese: false, storeOverride: store)),
    );
    await tester.pumpAndSettle();
    expect(find.text('cat'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<EnglishBand>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('菜鸡').last);
    await tester.pumpAndSettle();
    expect(find.text('cat'), findsNothing);
    expect(store.rows.length, 2);
    expect(store.rows.every((card) => card['discarded'] == false), isTrue);
    await tester.tap(find.byType(DropdownButton<EnglishBand>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文盲').last);
    await tester.pumpAndSettle();
    expect(find.text('cat'), findsOneWidget);
  });
}
