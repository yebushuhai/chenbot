/// Experimental item-selection primitives, not a calibrated vocabulary test.
/// A numeric score from these helpers must not be shown as a vocabulary estimate.
enum Level { h, g, f, e, d, c, b, a, s }

class AssessmentItem {
  const AssessmentItem({
    required this.id,
    required this.level,
    required this.calibrated,
  });
  final String id;
  final Level level;
  final bool calibrated;
}

class Answer {
  const Answer(this.item, this.correct);
  final AssessmentItem item;

  /// False includes "don't know"; guessing is handled by future calibration.
  final bool correct;
}

/// Selects a not-yet-seen calibrated question nearest the current working
/// difficulty. This only supplies a preliminary selection strategy, not a grade.
AssessmentItem? selectNext(List<AssessmentItem> bank, List<Answer> history) {
  final seen = history.map((a) => a.item.id).toSet();
  final available = bank
      .where((i) => i.calibrated && !seen.contains(i.id))
      .toList();
  if (available.isEmpty) return null;
  var target = Level.d.index;
  for (final answer in history) {
    target = (target + (answer.correct ? 1 : -1)).clamp(
      0,
      Level.values.length - 1,
    );
  }
  available.sort((a, b) {
    final distance = (a.level.index - target).abs().compareTo(
      (b.level.index - target).abs(),
    );
    return distance != 0 ? distance : a.id.compareTo(b.id);
  });
  return available.first;
}
