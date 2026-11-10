import 'package:flutter_test/flutter_test.dart';
import 'package:chenbot/dev_recognition.dart';

void main() {
  final valid = <String, dynamic>{
    'kind': 'object',
    'word': 'cat',
    'reading': '',
    'zh': '猫',
    'en_definition': 'A small animal.',
    'example': 'A cat sleeps.',
    'example_zh': '一只猫在睡觉。',
    'box': [0.1, 0.2, 0.8, 0.9],
  };
  test('parses a normalized object and rejects invalid locations', () {
    expect(DetectedWord.fromJson(valid).box, [0.1, 0.2, 0.8, 0.9]);
    expect(
      () => DetectedWord.fromJson({
        ...valid,
        'box': [0.8, 0.2, 0.1, 0.9],
      }),
      throwsFormatException,
    );
    expect(
      () => DetectedWord.fromJson({
        ...valid,
        'box': [0, 0, 2, 1],
      }),
      throwsFormatException,
    );
  });
  test('adjective fallback has no location', () {
    expect(
      DetectedWord.fromJson({...valid, 'kind': 'adjective', 'box': null}).box,
      isNull,
    );
    expect(
      () => DetectedWord.fromJson({...valid, 'kind': 'adjective'}),
      throwsFormatException,
    );
  });
  test('development bridge is disabled unless explicitly configured', () {
    expect(DevRecognition.enabled, isFalse);
  });
}
