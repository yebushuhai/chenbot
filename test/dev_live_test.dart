import 'dart:typed_data';

import 'package:chenbot/dev_recognition.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test(
    'local bridge recognizes a generated solid image',
    () async {
      final image = img.Image(width: 64, height: 64);
      img.fill(image, color: img.ColorRgb8(60, 110, 190));
      final words = await DevRecognition.recognize(
        Uint8List.fromList(img.encodePng(image)),
        'en',
      );
      expect(words, isNotEmpty);
      expect(words.first.word, isNotEmpty);
    },
    skip: !DevRecognition.enabled,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
