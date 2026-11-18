import 'package:chenbot/matching/secret_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const example = 'CB1-0001-0203-0405-0607-0809-0A0B-0C0D-0E0F-688D';
  const digest =
      '21f5cc13cf21a474a4a4ac04e2d611c4a40b0232c55e0a809ff457a146d343f4';
  test('protocol v1 is stable across paste and IME formatting', () {
    final fullwidth = String.fromCharCodes(
      example.toLowerCase().runes.map((c) => c + 0xFEE0),
    );
    for (final code in [
      example,
      example.toLowerCase(),
      example.replaceAll('-', '\u00a0\n'),
      fullwidth,
    ]) {
      expect(SecretCode.token(code), digest);
    }
  });
  test('every generated code can be redeemed and distinct codes differ', () {
    final tokens = List.generate(
      32,
      (_) => SecretCode.token(SecretCode.generate()),
    );
    expect(tokens.toSet(), hasLength(32));
    expect(tokens.every((t) => RegExp('^[0-9a-f]{64}\$').hasMatch(t)), isTrue);
  });
  test('rejects sensitive low-entropy text, confusables and bad checksums', () {
    for (final invalid in [
      '',
      '1992-01-01',
      '同济大学',
      ' abc ',
      example.replaceFirst('C', 'С'),
      example.replaceFirst('688D', '688E'),
      example.replaceFirst('0203', '020\u200b3'),
      '0' * 300,
    ]) {
      expect(() => SecretCode.token(invalid), throwsFormatException);
    }
  });
}
