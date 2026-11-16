import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'adaptive.dart';
import 'dev_recognition.dart';
import 'english_level.dart';

/// Comparison is intentionally conservative: no synonym or derivation guessing.
String normalizeVocabulary(String input, String language) {
  var value = input.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  value = value.replaceAll('’', "'");
  if (language == 'ja' &&
      RegExp(r'^[\u3041-\u3096\u30a1-\u30f6ー]+$').hasMatch(value)) {
    value = String.fromCharCodes(
      value.runes.map((c) => c >= 0x30a1 && c <= 0x30f6 ? c - 0x60 : c),
    );
  }
  return value;
}

class _InflectionGroup {
  _InflectionGroup(this.lemma, this.forms);
  final String lemma;
  final Set<String> forms;
}

/// Offline reference data. Ranks are subtitle word-form ranks, not vocabulary size.
class VocabularyLexicon {
  VocabularyLexicon._(this._ranks, this._groups);
  final Map<String, int> _ranks;
  final Map<String, List<_InflectionGroup>> _groups;
  static VocabularyLexicon? _cached;
  static Future<VocabularyLexicon>? _loading;

  static Future<VocabularyLexicon> load() {
    final ready = _cached;
    if (ready != null) return Future.value(ready);
    return _loading ??= _load().then(
      (value) {
        _cached = value;
        _loading = null;
        return value;
      },
      onError: (Object error, StackTrace stack) {
        _loading = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
  }

  static Future<VocabularyLexicon> _load() async {
    Future<String> asset(String path) async {
      final data = await rootBundle.load(path);
      return utf8.decode(
        gzip.decode(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        ),
      );
    }

    final parts = await Future.wait([
      asset('assets/vocabulary/english_subtitles_top500k.txt.gz'),
      asset('assets/vocabulary/english_inflections.csv.gz'),
    ]);
    final ranks = <String, int>{};
    var rank = 0;
    for (final line in const LineSplitter().convert(parts[0])) {
      rank++;
      final key = normalizeVocabulary(line, 'en');
      ranks.putIfAbsent(key, () => rank);
    }
    final groups = <String, List<_InflectionGroup>>{};
    for (final line in const LineSplitter().convert(parts[1])) {
      final columns = line.split(',');
      if (columns.length < 3 || columns.first.contains('"')) continue;
      final pos = columns[1];
      if (pos != 'noun' && pos != 'adj' && pos != 'verb') continue;
      final lemma = normalizeVocabulary(columns[0], 'en');
      final forms = <String>{lemma};
      for (final field in columns.skip(2)) {
        for (final value in field.split('/')) {
          final form = normalizeVocabulary(value, 'en');
          if (form.isNotEmpty && !form.contains('"')) forms.add(form);
        }
      }
      if (lemma.isEmpty) continue;
      final group = _InflectionGroup(lemma, forms);
      for (final form in forms) {
        groups.putIfAbsent('$pos:$form', () => []).add(group);
      }
    }
    return VocabularyLexicon._(ranks, groups);
  }

  int? rank(String word) => _ranks[normalizeVocabulary(word, 'en')];

  /// Only exact returned word forms present in the pinned table are eligible.
  List<DetectedWord> filterEnglishDifficulty(
    List<DetectedWord> words,
    EnglishBand selected,
  ) {
    final accepted = <DetectedWord>[];
    for (final word in words) {
      final localRank = rank(word.word);
      final band = englishBandForSubtitleRank(localRank);
      if (localRank != null &&
          band != null &&
          englishBandAllowed(band, selected)) {
        accepted.add(word.withFrequencyRank(localRank));
      }
    }
    return accepted;
  }

  /// Reject only terms known as adjectives with no noun entry; unknowns pass.
  bool isAdjectiveOnly(String word) {
    final value = normalizeVocabulary(word, 'en');
    return !value.contains(' ') &&
        _groups.containsKey('adj:$value') &&
        !_groups.containsKey('noun:$value');
  }

  Set<String> aliases({
    required String language,
    required String word,
    required String kind,
    String lemma = '',
    List<String> modelForms = const [],
  }) {
    final normalized = normalizeVocabulary(word, language);
    if (normalized.isEmpty) return {};
    final result = <String>{normalized};
    if (language == 'ja') {
      // Model-provided Japanese conjugations are helpful but not exhaustive.
      for (final form in [lemma, ...modelForms]) {
        final value = normalizeVocabulary(form, language);
        if (value.isNotEmpty && value.length <= 60) result.add(value);
      }
      if (kind == 'adjective' &&
          normalized.endsWith('い') &&
          normalized.length > 1) {
        if (normalized == 'いい') {
          result.addAll(['よい', 'よく', 'よかった', 'よくない', 'よくなかった']);
        } else {
          final stem = normalized.substring(0, normalized.length - 1);
          result.addAll([
            '$stemく',
            '$stemくて',
            '$stemくない',
            '$stemかった',
            '$stemくなかった',
          ]);
        }
      }
      return result;
    }
    // For a phrase, inflect its final word without hiding that word by itself.
    final space = normalized.lastIndexOf(' ');
    final prefix = space < 0 ? '' : normalized.substring(0, space + 1);
    final head = space < 0 ? normalized : normalized.substring(space + 1);
    final posOrder = kind == 'adjective'
        ? ['adj', 'noun', 'verb']
        : ['noun', 'verb', 'adj'];
    final options = [for (final pos in posOrder) ...?_groups['$pos:$head']];
    if (options.isNotEmpty) {
      final preferred = normalizeVocabulary(lemma, 'en');
      final matchingLemma = options.where((g) => g.lemma == preferred).toList();
      final matchingHead = options.where((g) => g.lemma == head).toList();
      final distinctLemmas = options.map((group) => group.lemma).toSet();
      final group = matchingLemma.isNotEmpty
          ? matchingLemma.first
          : matchingHead.isNotEmpty
          ? matchingHead.first
          : distinctLemmas.length == 1
          ? options.first
          : null;
      if (group != null) {
        // Include inflections of the same lemma across word classes. Never
        // equate an unrelated lemma merely because a surface form is shared.
        for (final pos in posOrder) {
          for (final related
              in _groups['$pos:${group.lemma}'] ?? <_InflectionGroup>[]) {
            if (related.lemma == group.lemma) {
              result.addAll(related.forms.map((form) => '$prefix$form'));
            }
          }
        }
      }
    }
    return result;
  }

  Set<String> matchingAliases(Map<String, dynamic> item) {
    final language = item['language'] as String? ?? 'en';
    final word = item['word'] as String? ?? '';
    var lemma = item['lemma'] as String? ?? '';
    // A kanji word's kana reading is ambiguous: 花 and 鼻 can both be はな.
    // Allow a kana surface form to match a stored reading, but do not let the
    // reading alone make two different kanji surface forms equivalent.
    if (language == 'ja' &&
        RegExp(r'[\u3400-\u9fff]').hasMatch(word) &&
        !RegExp(r'[\u3400-\u9fff]').hasMatch(lemma)) {
      lemma = '';
    }
    return aliases(
      language: language,
      word: word,
      kind: item['kind'] as String? ?? 'object',
      lemma: lemma,
    );
  }

  bool blocked(Map<String, dynamic> item, List<Map<String, dynamic>> trash) {
    final language = item['language'] as String? ?? 'en';
    final aliases = matchingAliases(item);
    return trash.any(
      (entry) =>
          entry['language'] == language &&
          (entry['aliases'] as List? ?? const []).whereType<String>().any(
            aliases.contains,
          ),
    );
  }

  /// Order eligible words, preferring the selected grade and missed practice.
  List<DetectedWord> order(
    List<DetectedWord> words,
    Level? level,
    Map<String, bool> practice,
  ) {
    if (level == null || words.length < 2) return words;
    final selected = englishBandForDifficulty(level);
    if (selected == null) return words;
    double score(DetectedWord item) {
      final key = normalizeVocabulary(item.word, 'en');
      final band = englishBandForSubtitleRank(rank(key));
      final frequencyScore = band == null
          ? -100.0
          : -(chenbotBands.indexOf(band) - chenbotBands.indexOf(selected))
                    .abs()
                    .toDouble() *
                2;
      final answer = practice[key];
      return frequencyScore +
          (answer == false
              ? 1.0
              : answer == true
              ? -0.3
              : 0);
    }

    final indexed = words.asMap().entries.toList();
    indexed.sort((a, b) {
      final comparison = score(b.value).compareTo(score(a.value));
      return comparison == 0 ? a.key.compareTo(b.key) : comparison;
    });
    return indexed.map((e) => e.value).toList();
  }
}

class VocabularyPractice {
  static String _key(String scope) => 'vocabulary_practice_v1_$scope';
  static Future<Map<String, bool>> load(String scope) async {
    final raw = (await SharedPreferences.getInstance()).getString(_key(scope));
    if (raw == null) return {};
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return {};
      return {
        for (final e in data.entries)
          if (e.key is String && e.value is bool)
            e.key as String: e.value as bool,
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> record(String scope, Map<String, bool> answers) async {
    final previous = await load(scope);
    for (final entry in answers.entries) {
      previous[normalizeVocabulary(entry.key, 'en')] = entry.value;
    }
    if (!await (await SharedPreferences.getInstance()).setString(
      _key(scope),
      jsonEncode(previous),
    )) {
      throw StateError('Unable to save practice evidence');
    }
  }
}
