import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Keep bearer credentials in device secure storage, isolated by endpoint.
class DeviceSessionStorage extends LocalStorage {
  DeviceSessionStorage(Uri endpoint)
    : _key = 'chenbot.session.${Uri.encodeComponent(endpoint.origin)}',
      _issuer = '${endpoint.origin}/auth/v1',
      _legacyKey = 'sb-${endpoint.host.split('.').first}-auth-token';

  final String _key, _issuer, _legacyKey;
  static const _vault = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
  );

  @override
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getString(_legacyKey);
    if (old == null) return;
    // The old SDK keyed sessions by a host prefix, shared by some endpoints.
    // Only import credentials issued by this deployment. The server still
    // verifies the JWT before accepting any request.
    bool sameIssuer = false;
    try {
      final jwt = (jsonDecode(old) as Map)['access_token'] as String;
      final payload = jwt.split('.')[1];
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(payload))),
      );
      sameIssuer = claims['iss'] == _issuer;
    } on Object {
      // An unreadable legacy entry requires a fresh OTP.
    }
    if (sameIssuer && !await hasAccessToken()) await persistSession(old);
    await prefs.remove(_legacyKey);
  }

  @override
  Future<String?> accessToken() => _vault.read(key: _key);
  @override
  Future<bool> hasAccessToken() => _vault.containsKey(key: _key);
  @override
  Future<void> persistSession(String persistSessionString) =>
      _vault.write(key: _key, value: persistSessionString);
  @override
  Future<void> removePersistedSession() => _vault.delete(key: _key);
}
