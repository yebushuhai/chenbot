import 'dart:typed_data';
import 'dart:math' as math;

import 'adaptive.dart';
import 'batch_store.dart';
import 'deepseek_recognition.dart';
import 'dev_recognition.dart';
import 'english_level.dart';
import 'vocabulary.dart';

class RecognitionOutcome {
  const RecognitionOutcome(
    this.words,
    this.requestCount, {
    this.noVisibleObject = false,
    this.noMatchingWords = false,
  });
  final List<DetectedWord> words;
  final int requestCount;
  final bool noVisibleObject;
  final bool noMatchingWords;
  bool get exhausted => words.isEmpty;
}

/// Remove repeated instances of the same surface word at nearly the same spot,
/// while retaining different names or the same word on different objects.
List<DetectedWord> _distinctCandidates(
  List<DetectedWord> items,
  String language,
) {
  final result = <DetectedWord>[];
  bool sameSpot(List<double>? a, List<double>? b) {
    if (a == null || b == null) return a == null && b == null;
    final width = math.max(0.0, math.min(a[2], b[2]) - math.max(a[0], b[0]));
    final height = math.max(0.0, math.min(a[3], b[3]) - math.max(a[1], b[1]));
    final intersection = width * height;
    final total =
        (a[2] - a[0]) * (a[3] - a[1]) +
        (b[2] - b[0]) * (b[3] - b[1]) -
        intersection;
    return total > 0 && intersection / total >= .8;
  }

  for (final item in items) {
    final word = normalizeVocabulary(item.word, language);
    if (result.any(
      (previous) =>
          normalizeVocabulary(previous.word, language) == word &&
          sameSpot(previous.box, item.box),
    )) {
      continue;
    }
    result.add(item);
  }
  return result;
}

/// At most two extra paid requests in total. A failed English level filter can
/// trigger one of them; the other retry reason is all results being in trash.
Future<RecognitionOutcome> recognizeForLearner({
  required Uint8List image,
  required String language,
  required String key,
  required DeepSeekRecognition service,
  required BatchStore store,
  Level? englishLevel,
  Map<String, bool> practice = const {},
}) async {
  final selectedBand = language == 'en'
      ? englishBandForDifficulty(englishLevel)
      : null;
  if (language == 'en' && selectedBand == null) {
    throw const DeepSeekException('请先选择英语识图等级。');
  }
  final lexicon = language == 'en' ? await VocabularyLexicon.load() : null;
  final excludedFromImage = <String>{};
  final previousRanks = <String, int?>{};
  var retriedForLevel = false;
  var sawNoMatchingWords = false;
  service.avoidOnRetry(const []);
  for (var attempt = 1; attempt <= 3; attempt++) {
    final raw = await service.recognize(image, language, key);
    var received = raw.where((item) => item.kind == 'object').toList();
    if (language == 'en' && received.isNotEmpty) {
      received = received
          .where((item) => !lexicon!.isAdjectiveOnly(item.word))
          .toList();
    }
    received = _distinctCandidates(received, language);
    if (received.isEmpty) {
      return RecognitionOutcome(
        [],
        attempt,
        noVisibleObject: excludedFromImage.isEmpty && !sawNoMatchingWords,
        noMatchingWords: sawNoMatchingWords,
      );
    }
    final allowed = await store.filterWords(received, language);
    if (allowed.isNotEmpty) {
      final matching = language == 'en'
          ? lexicon!.filterEnglishDifficulty(allowed, selectedBand!)
          : allowed;
      if (matching.isEmpty) {
        sawNoMatchingWords = true;
        if (language == 'en' && !retriedForLevel && attempt < 3) {
          retriedForLevel = true;
          excludedFromImage.addAll(received.map((word) => word.word));
          for (final word in allowed) {
            previousRanks[word.word] = lexicon!.rank(word.word);
          }
          service.avoidOnRetry(
            excludedFromImage,
            targetBand: selectedBand,
            previousRanks: previousRanks,
          );
          continue;
        }
        return RecognitionOutcome([], attempt, noMatchingWords: true);
      }
      final shouldOrder =
          language == 'en' && englishLevel != null && matching.length > 1;
      return RecognitionOutcome(
        shouldOrder
            ? lexicon!.order(matching, englishLevel, practice)
            : matching,
        attempt,
      );
    }
    excludedFromImage.addAll(received.map((word) => word.word));
    service.avoidOnRetry(
      excludedFromImage,
      targetBand: sawNoMatchingWords ? selectedBand : null,
      previousRanks: previousRanks,
    );
  }
  return RecognitionOutcome([], 3, noMatchingWords: sawNoMatchingWords);
}
