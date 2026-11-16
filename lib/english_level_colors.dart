import 'package:flutter/material.dart';

import 'english_level.dart';

/// The displayed word's locally checked frequency band determines its color.
Color? englishWordColor(Map<String, dynamic> card) {
  if (card['language'] != 'en') return null;
  final rank = card['frequencyRank'];
  final band = englishBandForSubtitleRank(rank is int ? rank : null);
  return switch (band?.id) {
    's' => const Color(0xffff00ff),
    'a' => const Color(0xffd6efff),
    'b' => const Color(0xffffd76a),
    'c' => const Color(0xffd8dadd),
    'd' => const Color(0xffe9c6a8),
    'f' => const Color(0xffd8efc9),
    'h' => Colors.white,
    _ => null,
  };
}

Color wordTextColor(Color? background) {
  if (background == null) return const Color(0xff192921);
  final luminance = background.computeLuminance();
  final blackContrast = (luminance + .05) / .05;
  final whiteContrast = 1.05 / (luminance + .05);
  return blackContrast >= whiteContrast ? Colors.black : Colors.white;
}
