import 'package:flutter_test/flutter_test.dart';
import 'package:chenbot/adaptive.dart';

void main() {
  const bank = [
    AssessmentItem(id: 'd', level: Level.d, calibrated: true),
    AssessmentItem(id: 'c', level: Level.c, calibrated: true),
    AssessmentItem(id: 'e', level: Level.e, calibrated: true),
    AssessmentItem(id: 'unreviewed', level: Level.d, calibrated: false),
  ];
  test('chooses only calibrated unseen items and adapts', () {
    expect(selectNext(bank, [])?.id, 'd');
    expect(selectNext(bank, [Answer(bank[0], true)])?.id, 'c');
    expect(selectNext(bank, [Answer(bank[0], false)])?.id, 'e');
    expect(
      selectNext(bank, [
        Answer(bank[0], true),
        Answer(bank[1], true),
        Answer(bank[2], false),
      ]),
      isNull,
    );
  });
}
