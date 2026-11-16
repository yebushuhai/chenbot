import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:chenbot/main.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  testWidgets('opens DeepSeek settings from the account page', (tester) async {
    await tester.pumpWidget(const Chenbot());
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DeepSeek 识图设置'));
    await tester.pumpAndSettle();
    expect(find.text('尚未设置 API Key'), findsOneWidget);
  });
  testWidgets('language selection works without a home assessment entry', (
    tester,
  ) async {
    await tester.pumpWidget(const Chenbot());
    await tester.tap(find.text('英语  ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日语').last);
    await tester.pumpAndSettle();
    expect(find.text('日语  ▾'), findsOneWidget);
    expect(find.text('体验日语水平测试'), findsNothing);
    expect(find.text('英语水平测试'), findsNothing);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('英语水平测试'), findsOneWidget);
  });
  testWidgets('example collection is hidden without deleting legacy data', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('saved_examples', ['coffee']);
    await tester.pumpWidget(const Chenbot());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const Chenbot());
    await tester.pumpAndSettle();
    await tester.tap(find.text('生词本'));
    await tester.pumpAndSettle();
    expect(find.text('coffee'), findsNothing);
    expect(find.text('示例收藏'), findsNothing);
    expect(prefs.getStringList('saved_examples'), ['coffee']);
    expect(find.text('把想记住的词留在这里。'), findsNothing);
  });
  testWidgets('unconnected payment is clearly unavailable', (tester) async {
    await tester.pumpWidget(const Chenbot());
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('识图额度'));
    await tester.pumpAndSettle();
    expect(find.textContaining('可能产生 DeepSeek 费用'), findsOneWidget);
  });

  testWidgets('English font uses Georgia on iOS and Gelasio on Android', (
    tester,
  ) async {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(const Chenbot());
    var theme = Theme.of(tester.element(find.byType(Home)));
    expect(theme.textTheme.bodyMedium!.fontFamily, 'Georgia');
    expect(theme.textTheme.bodyMedium!.fontFamilyFallback, contains('Gelasio'));
    expect(
      tester.widget<Text>(find.text('chenbot')).style!.fontFamily,
      'CupertinoSystemText',
    );
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(const Chenbot());
    theme = Theme.of(tester.element(find.byType(Home)));
    expect(theme.textTheme.bodyMedium!.fontFamily, 'Gelasio');
    expect(
      tester.widget<Text>(find.text('chenbot')).style!.fontFamily,
      'sans-serif',
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
