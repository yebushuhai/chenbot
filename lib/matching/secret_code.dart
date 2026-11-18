import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A bearer code for a single opt-in. Only [token]'s result goes to the RPC.
abstract final class SecretCode {
  static const _prefix = 'CB1';
  static const _tokenDomain = 'chenbot/secret-match/token/v1\x00';
  static const _checkDomain = 'chenbot/secret-match/check/v1\x00';
  static final _syntax = RegExp(r'^CB1([0-9A-F]{32})([0-9A-F]{4})$');
  // Unicode White_Space property, plus the ASCII hyphen used for grouping.
  static final _separators = RegExp(
    r'[-\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]',
  );

  static String generate() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    final groups = [for (var i = 0; i < 32; i += 4) hex.substring(i, i + 4)];
    return [_prefix, ...groups, _checksum(bytes)].join('-');
  }

  static String _checksum(List<int> bytes) => sha256
      .convert([...ascii.encode(_checkDomain), ...bytes])
      .toString()
      .substring(0, 4)
      .toUpperCase();

  static String token(String input) {
    const invalid = FormatException('请输入应用生成的完整口令');
    if (input.length > 256) throw invalid;
    // IMEs often insert fullwidth ASCII. Fold only this repertoire; accepting
    // arbitrary lookalikes or expanding Unicode case folds could change a code.
    final halfwidth = String.fromCharCodes(
      input.runes.map((r) => r >= 0xFF01 && r <= 0xFF5E ? r - 0xFEE0 : r),
    );
    final compact = halfwidth.replaceAll(_separators, '');
    if (compact.codeUnits.any((c) => c > 127)) throw invalid;
    final match = _syntax.firstMatch(compact.toUpperCase());
    if (match == null) throw invalid;
    final hex = match[1]!;
    final bytes = [
      for (var i = 0; i < 32; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    if (match[2] != _checksum(bytes)) throw invalid;
    return sha256.convert([...ascii.encode(_tokenDomain), ...bytes]).toString();
  }
}
