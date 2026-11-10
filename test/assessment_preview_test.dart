import 'package:chenbot/assessment_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final japanese in [false, true]) {
    testWidgets(
      'assessment preview has a don’t-know option and no false estimate ($japanese)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(home: AssessmentPreview(japanese: japanese)),
        );
        for (var i = 0; i < 5; i++) {
          await tester.ensureVisible(find.text('不认识'));
          await tester.tap(find.text('不认识'));
          await tester.pumpAndSettle();
        }
        expect(find.text('体验完成'), findsOneWidget);
        expect(find.textContaining('不能测算词汇量'), findsOneWidget);
        expect(find.textContaining('0 / 5'), findsOneWidget);
      },
    );
  }
}
