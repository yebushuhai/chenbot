import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chenbot/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('language selection changes example words and shows detail', (
    tester,
  ) async {
    await tester.pumpWidget(const Chenbot());
    await tester.tap(find.text('英语  ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日语').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('コーヒー'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(find.text('コーヒー'), findsOneWidget);
    await tester.tap(find.text('コーヒー'));
    await tester.pumpAndSettle();
    expect(find.text('朝、コーヒーを飲みます。'), findsOneWidget);
  });
  testWidgets('saved example survives reopening the app', (tester) async {
    await tester.pumpWidget(const Chenbot());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('coffee'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -150));
    await tester.pumpAndSettle();
    await tester.tap(find.text('coffee'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收藏'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const Chenbot());
    await tester.pumpAndSettle();
    await tester.tap(find.text('生词本'));
    await tester.pumpAndSettle();
    expect(find.text('coffee'), findsOneWidget);
  });
  testWidgets('unconnected payment is clearly unavailable', (tester) async {
    await tester.pumpWidget(const Chenbot());
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('识图额度'));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前不会产生收费'), findsOneWidget);
  });
}
