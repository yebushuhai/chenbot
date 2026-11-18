import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chenbot/matching/session_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'migrates the configured endpoint session and erases its old copy',
    () async {
      final claims = base64Url.encode(
        utf8.encode('{"iss":"https://test.example/auth/v1"}'),
      );
      final session = jsonEncode({
        'access_token': 'header.$claims.signature',
        'refresh_token': 'test',
      });
      SharedPreferences.setMockInitialValues({'sb-test-auth-token': session});
      FlutterSecureStorage.setMockInitialValues({});
      final store = DeviceSessionStorage(Uri.parse('https://test.example'));
      await store.initialize();
      expect(await store.accessToken(), session);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          'sb-test-auth-token',
        ),
        false,
      );
      final other = DeviceSessionStorage(Uri.parse('https://test.other'));
      expect(await other.hasAccessToken(), false);
      await store.removePersistedSession();
      expect(await store.hasAccessToken(), false);
    },
  );
}
