import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class DetectedWord {
  const DetectedWord({
    required this.kind,
    required this.word,
    required this.reading,
    required this.zh,
    required this.definition,
    required this.example,
    required this.exampleZh,
    required this.box,
    this.lemma = '',
    this.forms = const [],
    this.frequencyRank,
  });
  final String kind, word, reading, zh, definition, example, exampleZh;
  final List<double>? box;
  final String lemma;
  final List<String> forms;

  /// Locally verified subtitle word-form position, never a model claim.
  final int? frequencyRank;

  DetectedWord withFrequencyRank(int rank) => DetectedWord(
    kind: kind,
    word: word,
    reading: reading,
    zh: zh,
    definition: definition,
    example: example,
    exampleZh: exampleZh,
    box: box,
    lemma: lemma,
    forms: forms,
    frequencyRank: rank,
  );
  factory DetectedWord.fromJson(Map<String, dynamic> value) {
    String text(String key) {
      final v = value[key];
      if (v is! String ||
          v.length > 500 ||
          (key != 'reading' && v.trim().isEmpty)) {
        throw const FormatException('Invalid result');
      }
      return v;
    }

    final kind = text('kind');
    if (kind != 'object' && kind != 'adjective') {
      throw const FormatException('Invalid kind');
    }
    List<double>? box;
    if (kind == 'object') {
      final raw = value['box'];
      if (raw is! List ||
          raw.length != 4 ||
          raw.any((v) => v is! num || !v.isFinite || v < 0 || v > 1)) {
        throw const FormatException('Invalid box');
      }
      box = raw.map((v) => (v as num).toDouble()).toList();
      if (box[0] >= box[2] || box[1] >= box[3]) {
        throw const FormatException('Invalid box');
      }
    } else if (value['box'] != null) {
      throw const FormatException('Invalid adjective');
    }
    return DetectedWord(
      kind: kind,
      word: text('word'),
      reading: text('reading'),
      zh: text('zh'),
      definition: text('en_definition'),
      example: text('example'),
      exampleZh: text('example_zh'),
      box: box,
      lemma: value['lemma'] is String && (value['lemma'] as String).length <= 60
          ? value['lemma'] as String
          : '',
      forms: value['forms'] is List
          ? (value['forms'] as List)
                .whereType<String>()
                .where((s) => s.isNotEmpty && s.length <= 60)
                .take(20)
                .toList()
          : const [],
    );
  }
}

class DevRecognition {
  static const token = String.fromEnvironment('CHENBOT_DEV_TOKEN');
  static const _base = String.fromEnvironment(
    'CHENBOT_DEV_URL',
    defaultValue: 'http://127.0.0.1:3218',
  );
  static bool get enabled => kDebugMode && token.length >= 24;
  static Future<List<DetectedWord>> recognize(
    Uint8List bytes,
    String language,
  ) async {
    if (!enabled) throw StateError('识图服务尚未配置');
    final base = Uri.parse(_base);
    if (base.scheme != 'http' ||
        (base.host != '127.0.0.1' && base.host != 'localhost') ||
        base.userInfo.isNotEmpty) {
      throw StateError('仅允许本机开发服务');
    }
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw StateError('图片过大或为空');
    }
    final jpeg =
        bytes.length > 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
    final png =
        bytes.length > 8 &&
        listEquals(bytes.sublist(0, 8), const [
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
        ]);
    if (!jpeg && !png) throw StateError('请选择 JPEG 或 PNG 图片');
    final response = await http
        .post(
          base.replace(path: '/v1/recognize', query: null, fragment: null),
          headers: {
            'content-type': 'application/json',
            'x-chenbot-dev-token': token,
          },
          body: jsonEncode({
            'image': base64Encode(bytes),
            'mimeType': jpeg ? 'image/jpeg' : 'image/png',
            'language': language,
          }),
        )
        .timeout(const Duration(seconds: 70));
    if (response.statusCode != 200) throw StateError('识别失败，请检查本机服务和网络');
    final data = jsonDecode(response.body);
    if (data is! Map ||
        data['items'] is! List ||
        (data['items'] as List).isEmpty ||
        (data['items'] as List).length > 8) {
      throw const FormatException('Invalid result');
    }
    return (data['items'] as List)
        .map((v) => DetectedWord.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
  }
}
