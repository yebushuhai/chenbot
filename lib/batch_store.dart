import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'dev_recognition.dart';
import 'image_prepare.dart';
import 'vocabulary.dart';

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
  Future<void> moveLabel(String id, double x, double y) => _serialize(() async {
    if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
      throw const FormatException('Invalid label position');
    }
    final all = await cards();
    final index = all.indexWhere((card) => card['id'] == id);
    if (index < 0) throw StateError('Card not found');
    all[index]['labelX'] = x;
    all[index]['labelY'] = y;
    await _write('cards.json', all);
  });
  Future<void> restore(String id) => _serialize(() => _restore(id));
  Future<void> addTrashAlias(String id, String value) => _serialize(() async {
    final entries = await _ensureTrash();
    final index = entries.indexWhere((entry) => entry['id'] == id);
    if (index < 0) throw StateError('Trash entry not found');
    final entry = entries[index];
    final language = entry['language'] as String;
    final normalized = normalizeVocabulary(value, language);
    if (normalized.isEmpty || normalized.length > 60) {
      throw const FormatException('词形不能为空或超过 60 个字符');
    }
    final lexicon = await VocabularyLexicon.load();
    final aliases = (entry['aliases'] as List).whereType<String>().toSet();
    aliases.addAll(
      lexicon.aliases(
        language: language,
        word: normalized,
        kind: entry['kind'] as String? ?? 'object',
      ),
    );
    if (aliases.length > 250) throw const FormatException('词形数量过多');
    entry['aliases'] = aliases.toList()..sort();
    await _write('trash.json', entries);
  });
  Future<void> restoreMatching(Map<String, dynamic> card) =>
      _serialize(() async {
        final entries = await _ensureTrash();
        final lexicon = await VocabularyLexicon.load();
        final matches = entries
            .where((entry) => lexicon.blocked(card, [entry]))
            .toList();
        for (final entry in matches) {
          await _restore(entry['id'] as String);
        }
      });
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
  Future<List<Map<String, dynamic>>> trash() => _serialize(_ensureTrash);

  Future<List<Map<String, dynamic>>> visibleCards() async {
    final entries = await trash();
    final all = await cards();
    if (all.isEmpty) return [];
    final needsLexicon =
        entries.isNotEmpty || all.any((card) => card['language'] == 'en');
    final lexicon = needsLexicon ? await VocabularyLexicon.load() : null;
    final result = <Map<String, dynamic>>[];
    for (final card in all) {
      if (card['discarded'] == true || card['kind'] == 'adjective') continue;
      if (entries.isNotEmpty && lexicon!.blocked(card, entries)) continue;
      if (card['language'] == 'en') {
        final rank = lexicon!.rank(card['word'] as String? ?? '');
        // Keep historical records on disk; unlisted forms are not displayed.
        if (rank == null) continue;
        result.add({...card, 'frequencyRank': rank});
      } else {
        result.add(card);
      }
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> visibleFavorites() async {
    final entries = await trash();
    if (entries.isEmpty) return favorites();
    final lexicon = await VocabularyLexicon.load();
    return (await favorites())
        .where((card) => !lexicon.blocked(card, entries))
        .toList();
  }

  Future<List<DetectedWord>> filterWords(
    List<DetectedWord> words,
    String language,
  ) => _serialize(() async {
    final entries = await _ensureTrash();
    if (entries.isEmpty) return words;
    final lexicon = await VocabularyLexicon.load();
    final allowed = <DetectedWord>[];
    var changed = false;
    for (final word in words) {
      final aliases = lexicon.aliases(
        language: language,
        word: word.word,
        kind: word.kind,
        lemma: word.lemma,
        modelForms: word.forms,
      );
      final matchAliases = lexicon.matchingAliases({
        'language': language,
        'word': word.word,
        'kind': word.kind,
        'lemma': word.lemma,
      });
      var blocked = false;
      for (final entry in entries) {
        if (entry['language'] != language) continue;
        final existing = (entry['aliases'] as List? ?? const [])
            .whereType<String>()
            .toSet();
        if (!existing.any(matchAliases.contains)) continue;
        blocked = true;
        final before = existing.length;
        for (final alias in aliases) {
          if (existing.length < 250) existing.add(alias);
        }
        if (existing.length != before) {
          entry['aliases'] = existing.toList()..sort();
          changed = true;
        }
      }
      if (!blocked) allowed.add(word);
    }
    if (changed) await _write('trash.json', entries);
    return allowed;
  });

  Future<Uint8List> readPhoto(Map<String, dynamic> photo) =>
      _file(photo['file'] as String).readAsBytes();
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
    final blocked = await _ensureTrash();
    final lexicon = blocked.isEmpty ? null : await VocabularyLexicon.load();
    all.removeWhere((card) => card['photoId'] == photo['id']);
    var savedCount = 0;
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      if (lexicon != null &&
          lexicon.blocked({
            'language': photo['language'],
            'word': w.word,
            'kind': w.kind,
            'lemma': w.lemma,
            'forms': w.forms,
          }, blocked)) {
        continue;
      }
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
        'lemma': w.lemma,
        'forms': w.forms,
        if (w.frequencyRank != null) 'frequencyRank': w.frequencyRank,
        'discarded': false,
      });
      savedCount++;
    }
    await _write('cards.json', all);
    await _setStatus(
      photo['id'] as String,
      savedCount == 0 ? 'no_match' : 'processed',
    );
  }

  Future<void> _setStatus(String id, String status) async {
    final all = await photos();
    final index = all.indexWhere((p) => p['id'] == id);
    if (index < 0) throw StateError('Photo not found');
    all[index]['status'] = status;
    await _write('photos.json', all);
  }

  Future<List<Map<String, dynamic>>> _ensureTrash() async {
    if (await _file('trash.json').exists()) return _read('trash.json');
    final oldDiscarded = (await cards())
        .where((card) => card['discarded'] == true)
        .toList();
    if (oldDiscarded.isEmpty) {
      await _write('trash.json', []);
      return [];
    }
    final lexicon = await VocabularyLexicon.load();
    final entries = <Map<String, dynamic>>[];
    for (final card in oldDiscarded) {
      if (lexicon.blocked(card, entries)) continue;
      entries.add(_trashEntry(card, lexicon));
    }
    await _write('trash.json', entries);
    return entries;
  }

  Map<String, dynamic> _trashEntry(
    Map<String, dynamic> card,
    VocabularyLexicon lexicon,
  ) {
    final language = card['language'] as String;
    final aliases =
        lexicon
            .aliases(
              language: language,
              word: card['word'] as String,
              kind: card['kind'] as String? ?? 'object',
              lemma: card['lemma'] as String? ?? '',
              modelForms: (card['forms'] as List? ?? const [])
                  .whereType<String>()
                  .toList(),
            )
            .toList()
          ..sort();
    final reading = card['reading'] as String? ?? '';
    if (language == 'ja' &&
        RegExp(r'^[\u3041-\u3096\u30a1-\u30f6ー]+$').hasMatch(reading)) {
      final normalizedReading = normalizeVocabulary(reading, 'ja');
      if (!aliases.contains(normalizedReading)) {
        aliases.add(normalizedReading);
        aliases.sort();
      }
    }
    return {
      'id': _id(),
      'language': language,
      'kind': card['kind'] ?? 'object',
      'word': card['word'],
      'zh': card['zh'] ?? '',
      'aliases': aliases,
    };
  }

  Future<void> _discard(String id) async {
    final all = await cards();
    final index = all.indexWhere((c) => c['id'] == id);
    if (index < 0) throw StateError('Card not found');
    final entries = await _ensureTrash();
    final lexicon = await VocabularyLexicon.load();
    if (!lexicon.blocked(all[index], entries)) {
      entries.add(_trashEntry(all[index], lexicon));
      await _write('trash.json', entries);
    }
    all[index]['discarded'] = true;
    await _write('cards.json', all);
  }

  Future<void> _restore(String id) async {
    final entries = await _ensureTrash();
    final index = entries.indexWhere((entry) => entry['id'] == id);
    if (index < 0) throw StateError('Trash entry not found');
    final entry = entries[index];
    final lexicon = await VocabularyLexicon.load();
    final all = await cards();
    for (final card in all) {
      if (lexicon.blocked(card, [entry])) card['discarded'] = false;
    }
    await _write('cards.json', all);
    entries.removeAt(index);
    await _write('trash.json', entries);
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
          'kind',
          'lemma',
          'forms',
        ])
          key: card[key],
      });
      await _write('favorites.json', all);
    }
  }
}
