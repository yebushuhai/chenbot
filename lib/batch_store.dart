import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'dev_recognition.dart';
import 'image_prepare.dart';

/// Local-only development store. No account sync or production encryption.
String localScopeForUser(String? userId) {
  if (userId == null) return 'guest';
  if (!RegExp(
    r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
  ).hasMatch(userId)) {
    throw const FormatException('Invalid account identifier');
  }
  return userId.toLowerCase();
}

class BatchStore {
  BatchStore(this.root);
  final Directory root;
  final _random = Random.secure();
  static Future<void> _tail = Future.value();
  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Map<String, dynamic>> addPhoto(Uint8List bytes, String language) =>
      _serialize(() => _addPhoto(bytes, language));
  Future<void> saveResults(
    Map<String, dynamic> photo,
    List<DetectedWord> words,
  ) => _serialize(() => _saveResults(photo, words));
  Future<void> setStatus(String id, String status) =>
      _serialize(() => _setStatus(id, status));
  Future<void> discard(String id) => _serialize(() => _discard(id));
  Future<void> favorite(Map<String, dynamic> card) =>
      _serialize(() => _favorite(card));

  String _id() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  File _file(String name) => File('${root.path}/$name');
  Future<List<Map<String, dynamic>>> _read(String name) async {
    final file = _file(name);
    if (!await file.exists()) return [];
    final data = jsonDecode(await file.readAsString());
    if (data is! List) throw const FormatException('Invalid local data');
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> _write(String name, List<Map<String, dynamic>> data) async {
    await root.create(recursive: true);
    final temp = _file('$name.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    await temp.rename(_file(name).path);
  }

  Future<List<Map<String, dynamic>>> photos() => _read('photos.json');
  Future<List<Map<String, dynamic>>> cards() => _read('cards.json');
  Future<List<Map<String, dynamic>>> favorites() => _read('favorites.json');
  Future<Map<String, dynamic>> _addPhoto(
    Uint8List bytes,
    String language,
  ) async {
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('图片大小不受支持');
    }
    final clean = await preparePhoto(bytes);
    await root.create(recursive: true);
    final id = _id();
    final filename = '$id.jpg';
    await _file(filename).writeAsBytes(clean, flush: true);
    final photo = <String, dynamic>{
      'id': id,
      'file': filename,
      'language': language,
      'status': 'queued',
    };
    try {
      final all = await photos();
      all.add(photo);
      await _write('photos.json', all);
    } catch (_) {
      await _file(filename).delete();
      rethrow;
    }
    return photo;
  }

  Future<void> _saveResults(
    Map<String, dynamic> photo,
    List<DetectedWord> words,
  ) async {
    final all = await cards();
    all.removeWhere((card) => card['photoId'] == photo['id']);
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      all.add({
        'id': '${photo['id']}_$i',
        'photoId': photo['id'],
        'file': photo['file'],
        'language': photo['language'],
        'kind': w.kind,
        'word': w.word,
        'reading': w.reading,
        'zh': w.zh,
        'en_definition': w.definition,
        'example': w.example,
        'example_zh': w.exampleZh,
        'box': w.box,
        'discarded': false,
      });
    }
    await _write('cards.json', all);
    await _setStatus(photo['id'] as String, 'processed');
  }

  Future<void> _setStatus(String id, String status) async {
    final all = await photos();
    final index = all.indexWhere((p) => p['id'] == id);
    if (index < 0) throw StateError('Photo not found');
    all[index]['status'] = status;
    await _write('photos.json', all);
  }

  Future<void> _discard(String id) async {
    final all = await cards();
    final index = all.indexWhere((c) => c['id'] == id);
    if (index < 0) throw StateError('Card not found');
    all[index]['discarded'] = true;
    await _write('cards.json', all);
  }

  Future<void> _favorite(Map<String, dynamic> card) async {
    final all = await favorites();
    if (!all.any(
      (f) =>
          f['language'] == card['language'] &&
          f['word'] == card['word'] &&
          f['reading'] == card['reading'],
    )) {
      all.add({
        for (final key in [
          'language',
          'word',
          'reading',
          'zh',
          'en_definition',
          'example',
          'example_zh',
        ])
          key: card[key],
      });
      await _write('favorites.json', all);
    }
  }
}
