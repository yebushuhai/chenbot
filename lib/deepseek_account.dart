import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class DeepSeekBalance {
  const DeepSeekBalance(this.available, this.entries);
  final bool available;
  final List<DeepSeekBalanceEntry> entries;
}

class DeepSeekBalanceEntry {
  const DeepSeekBalanceEntry(
    this.currency,
    this.total,
    this.granted,
    this.toppedUp,
  );
  final String currency, total, granted, toppedUp;
}

/// DeepSeek's public API returns current balances, not lifetime account spend.
class DeepSeekAccountApi {
  DeepSeekAccountApi({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<DeepSeekBalance> balance(String key) async {
    final request =
        http.Request('GET', Uri.https('api.deepseek.com', '/user/balance'))
          ..followRedirects = false
          ..headers['authorization'] = 'Bearer $key';
    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        await response.stream.drain<void>().timeout(
          const Duration(seconds: 15),
        );
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw const DeepSeekAccountException('API Key 无效或没有查询余额的权限。');
        }
        throw DeepSeekAccountException('余额查询失败（HTTP ${response.statusCode}）。');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 15),
      )) {
        if (bytes.length + chunk.length > 65536) throw const FormatException();
        bytes.addAll(chunk);
      }
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map ||
          data['is_available'] is! bool ||
          data['balance_infos'] is! List) {
        throw const FormatException();
      }
      final entries = <DeepSeekBalanceEntry>[];
      final decimal = RegExp(r'^\d+(?:\.\d+)?$');
      for (final raw in data['balance_infos'] as List) {
        if (raw is! Map ||
            raw['currency'] is! String ||
            raw['total_balance'] is! String ||
            raw['granted_balance'] is! String ||
            raw['topped_up_balance'] is! String) {
          throw const FormatException();
        }
        final currency = raw['currency'] as String;
        final total = raw['total_balance'] as String;
        final granted = raw['granted_balance'] as String;
        final toppedUp = raw['topped_up_balance'] as String;
        if (!RegExp(r'^[A-Z]{3}$').hasMatch(currency) ||
            !decimal.hasMatch(total) ||
            !decimal.hasMatch(granted) ||
            !decimal.hasMatch(toppedUp)) {
          throw const FormatException();
        }
        entries.add(DeepSeekBalanceEntry(currency, total, granted, toppedUp));
      }
      return DeepSeekBalance(data['is_available'] as bool, entries);
    } on DeepSeekAccountException {
      rethrow;
    } catch (_) {
      throw const DeepSeekAccountException('无法查询余额，请检查网络后重试。');
    }
  }

  void close() => _client.close();
}

class DeepSeekAccountException implements Exception {
  const DeepSeekAccountException(this.message);
  final String message;
}

class LocalTokenUsage {
  const LocalTokenUsage({this.requests = 0, this.input = 0, this.output = 0});
  final int requests, input, output;

  static LocalTokenUsage? fromResponse(Object? data) {
    if (data is! Map) return null;
    final input = data['prompt_tokens'];
    final output = data['completion_tokens'];
    if (input is! int ||
        output is! int ||
        input < 0 ||
        output < 0 ||
        input > 1000000000 ||
        output > 1000000000) {
      return null;
    }
    return LocalTokenUsage(requests: 1, input: input, output: output);
  }
}

/// Counts only returned usage for this local profile, beginning with this feature.
class DeepSeekUsageStore {
  DeepSeekUsageStore(this.scope);
  final String scope;
  static Future<void> _tail = Future.value();
  String get _key => 'deepseek_local_usage_v1_$scope';

  Future<LocalTokenUsage> read() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = prefs.getString(_key);
      if (raw == null) return const LocalTokenUsage();
      final value = jsonDecode(raw) as Map;
      final requests = value['requests'],
          input = value['input'],
          output = value['output'];
      if (requests is! int ||
          input is! int ||
          output is! int ||
          requests < 0 ||
          input < 0 ||
          output < 0) {
        return const LocalTokenUsage();
      }
      return LocalTokenUsage(requests: requests, input: input, output: output);
    } catch (_) {
      return const LocalTokenUsage();
    }
  }

  Future<void> record(LocalTokenUsage delta) {
    final done = _tail.then((_) async {
      final old = await read();
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(
        _key,
        jsonEncode({
          'requests': old.requests + delta.requests,
          'input': old.input + delta.input,
          'output': old.output + delta.output,
        }),
      )) {
        throw StateError('Could not save local usage');
      }
    });
    _tail = done.then<void>((_) {}, onError: (Object _) {});
    return done;
  }
}
