import 'dart:convert';
import 'dart:typed_data';

import 'package:chenbot/adaptive.dart';
import 'package:chenbot/deepseek_account.dart';
import 'package:chenbot/deepseek_recognition.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'gets actual balance with a non-redirecting authorized request',
    () async {
      final api = DeepSeekAccountApi(
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://api.deepseek.com/user/balance',
          );
          expect(request.headers['authorization'], 'Bearer test-only-key');
          expect(request.followRedirects, isFalse);
          return http.Response(
            jsonEncode({
              'is_available': true,
              'balance_infos': [
                {
                  'currency': 'CNY',
                  'total_balance': '12.34',
                  'granted_balance': '2.34',
                  'topped_up_balance': '10.00',
                },
                {
                  'currency': 'USD',
                  'total_balance': '1.00',
                  'granted_balance': '0',
                  'topped_up_balance': '1.00',
                },
              ],
            }),
            200,
          );
        }),
      );
      final result = await api.balance('test-only-key');
      expect(result.available, isTrue);
      expect(result.entries.map((e) => e.total), ['12.34', '1.00']);
      api.close();
    },
  );

  test('balance errors never expose provider responses or keys', () async {
    for (final status in [401, 403, 302, 500]) {
      final api = DeepSeekAccountApi(
        client: MockClient(
          (_) async => http.Response('private test-only-key', status),
        ),
      );
      try {
        await api.balance('test-only-key');
        fail('Expected failure');
      } on DeepSeekAccountException catch (e) {
        expect(e.message, isNot(contains('test-only-key')));
        expect(e.message, isNot(contains('private')));
      }
      api.close();
    }
  });

  test(
    'records returned token usage even when model content is invalid',
    () async {
      final store = DeepSeekUsageStore('guest');
      final service = DeepSeekRecognition(
        onUsage: store.record,
        englishLevel: Level.c,
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          expect(
            body['messages'][0]['content'][0]['text'],
            contains('difficulty C'),
          );
          return http.Response(
            jsonEncode({
              'usage': {'prompt_tokens': 123, 'completion_tokens': 45},
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {'content': 'not JSON'},
                },
              ],
            }),
            200,
          );
        }),
      );
      await expectLater(
        service.recognize(
          Uint8List.fromList([255, 216, 255, 1]),
          'en',
          'test-key',
        ),
        throwsA(isA<DeepSeekException>()),
      );
      final saved = await store.read();
      expect([saved.requests, saved.input, saved.output], [1, 123, 45]);
      expect((await DeepSeekUsageStore('another-user').read()).requests, 0);
      service.close();
    },
  );
}
