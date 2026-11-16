import 'dart:convert';
import 'dart:typed_data';

import 'package:chenbot/deepseek_recognition.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _image = Uint8List.fromList([0xff, 0xd8, 0xff, 1]);
const _testKey = 'test-key-not-a-real-credential';
final _validItem = <String, Object?>{
  'kind': 'object',
  'word': 'りんご',
  'reading': 'りんご',
  'zh': '苹果',
  'en_definition': 'A fruit.',
  'example': 'りんごを食べます。',
  'example_zh': '我吃苹果。',
  'box': [0.1, 0.2, 0.8, 0.9],
};

String _response(Object data, {String finish = 'stop'}) => jsonEncode({
  'choices': [
    {
      'finish_reason': finish,
      'message': {'content': jsonEncode(data)},
    },
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'stores keys separately for guest and accounts and removes only one',
    () async {
      final guest = DeepSeekKeyStore('guest');
      final user = DeepSeekKeyStore('00000000-0000-0000-0000-000000000001');
      await guest.save(' guest-key ');
      await user.save('user-key');
      expect(await guest.read(), 'guest-key');
      expect(await user.read(), 'user-key');
      await guest.delete();
      expect(await guest.hasKey(), isFalse);
      expect(await user.read(), 'user-key');
      await expectLater(user.save('not a valid key'), throwsFormatException);
      expect(await user.read(), 'user-key');
    },
  );

  test(
    'sends one image directly over HTTPS and parses a Japanese result',
    () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://api.deepseek.com/chat/completions',
        );
        expect(request.followRedirects, isFalse);
        expect(request.headers['authorization'], 'Bearer $_testKey');
        final body = jsonDecode(request.body) as Map;
        expect(body['model'], 'deepseek-flash');
        expect(body['safety_check'], {'level': 'high'});
        expect(body['response_format'], {'type': 'text'});
        expect(body['thinking'], {'type': 'disabled'});
        final content = (body['messages'] as List).single['content'] as List;
        expect(content.first['text'], contains('Japanese'));
        expect(
          content.last['image_url']['url'],
          'data:image/jpeg;base64,${base64Encode(_image)}',
        );
        return http.Response(
          _response({
            'items': [_validItem],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = DeepSeekRecognition(client: client);
      final result = await service.recognize(_image, 'ja', _testKey);
      expect(result.single.word, 'りんご');
      expect(result.single.box, [0.1, 0.2, 0.8, 0.9]);
      service.close();
    },
  );

  test('requests and accepts 32 candidates in one image call', () async {
    var requests = 0;
    final filler = List.filled(450, 'x').join();
    final client = MockClient((request) async {
      requests++;
      final body = jsonDecode(request.body) as Map;
      expect(body['max_tokens'], 8192);
      final content = (body['messages'] as List).single['content'] as List;
      expect(content.first['text'], contains('up to 32 word entries'));
      expect(content.first['text'], contains('Never invent objects'));
      expect(content.where((part) => part['type'] == 'image_url').length, 1);
      final items = [
        for (var i = 0; i < 32; i++)
          {
            ..._validItem,
            'word': 'candidate$i',
            'en_definition': filler,
            'example': filler,
          },
      ];
      expect(jsonEncode({'items': items}).length, greaterThan(20000));
      return http.Response(
        _response({'items': items}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final service = DeepSeekRecognition(client: client);
    final result = await service.recognize(_image, 'en', _testKey);
    expect(result.length, 32);
    expect(result.last.word, 'candidate31');
    expect(requests, 1);
    service.close();
  });

  test(
    'one malformed candidate does not discard the other valid words',
    () async {
      final service = DeepSeekRecognition(
        client: MockClient(
          (_) async => http.Response(
            _response({
              'items': [
                {..._validItem, 'word': 'first'},
                {
                  ..._validItem,
                  'box': [0, 0, 2, 1],
                },
                {..._validItem, 'word': 'second'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      final result = await service.recognize(_image, 'en', _testKey);
      expect(result.map((word) => word.word), ['first', 'second']);
      service.close();
    },
  );

  test('rejects a response exceeding the bounded candidate limit', () async {
    final service = DeepSeekRecognition(
      client: MockClient(
        (_) async => http.Response(
          _response({'items': List.filled(49, _validItem)}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    await expectLater(
      service.recognize(_image, 'en', _testKey),
      throwsA(isA<DeepSeekException>()),
    );
    service.close();
  });

  test('reports authentication and balance failures without exposing the response or key', () async {
    for (final status in [401, 402, 403, 429, 302]) {
      final service = DeepSeekRecognition(
        client: MockClient(
          (_) async => http.Response('private response $_testKey', status),
        ),
      );
      try {
        await service.recognize(_image, 'en', _testKey);
        fail('Expected an error for $status');
      } on DeepSeekException catch (error) {
        expect(error.message, isNot(contains(_testKey)));
        expect(error.message, isNot(contains('private response')));
        if (status == 402) expect(error.message, contains('余额不足'));
        if (status == 401 || status == 403) {
          expect(error.message, contains('API Key'));
        }
      } finally {
        service.close();
      }
    }
  });

  test('rejects invalid model output and unsafe input', () async {
    final outputs = [
      {
        'items': [
          {
            ..._validItem,
            'box': [0, 0, 2, 1],
          },
        ],
      },
    ];
    for (final data in outputs) {
      final service = DeepSeekRecognition(
        client: MockClient(
          (_) async => http.Response(
            _response(data),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      await expectLater(
        service.recognize(_image, 'en', _testKey),
        throwsA(isA<DeepSeekException>()),
      );
      service.close();
    }
    var sent = false;
    final service = DeepSeekRecognition(
      client: MockClient((_) async {
        sent = true;
        return http.Response('', 200);
      }),
    );
    await expectLater(
      service.recognize(Uint8List.fromList([0, 1]), 'en', _testKey),
      throwsA(isA<DeepSeekException>()),
    );
    expect(sent, isFalse);
    service.close();
  });

  test('ignores a descriptive adjective without coordinates', () async {
    final item = {..._validItem, 'kind': 'adjective', 'box': null};
    final service = DeepSeekRecognition(
      client: MockClient(
        (_) async => http.Response(
          _response({
            'items': [item],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    final words = await service.recognize(_image, 'en', _testKey);
    expect(words, isEmpty);
    service.close();
  });

  test(
    'parses valid JSON when the model adds a fence or a short preface',
    () async {
      final json = jsonEncode({
        'items': [_validItem],
      });
      for (final content in [
        '  ```json\n$json\n```',
        'Here are the words:\n$json',
      ]) {
        final response = jsonEncode({
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {'content': content},
            },
          ],
        });
        final service = DeepSeekRecognition(
          client: MockClient(
            (_) async => http.Response(
              response,
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        final result = await service.recognize(_image, 'ja', _testKey);
        expect(result.single.word, 'りんご');
        service.close();
      }
    },
  );

  test('keeps a visible object and ignores an adjective', () async {
    final adjective = {
      ..._validItem,
      'kind': 'adjective',
      'word': '明るい',
      'box': null,
    };
    final service = DeepSeekRecognition(
      client: MockClient(
        (_) async => http.Response(
          _response({
            'items': [_validItem, adjective],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    final result = await service.recognize(_image, 'ja', _testKey);
    expect(result.map((item) => item.kind), ['object']);
    service.close();
  });
}
