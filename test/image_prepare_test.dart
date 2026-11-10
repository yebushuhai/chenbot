import 'dart:typed_data';

import 'package:chenbot/image_prepare.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('applies orientation and strips EXIF metadata', () async {
    final photo = img.Image(width: 3, height: 2);
    photo.exif.imageIfd.orientation = 6;
    final prepared = await preparePhoto(
      Uint8List.fromList(img.encodeJpg(photo)),
    );
    final decoded = img.decodeJpg(prepared)!;
    expect(decoded.width, 2);
    expect(decoded.height, 3);
    expect(decoded.exif.imageIfd.hasOrientation, isFalse);
  });
  test('rejects corrupt or unsupported inputs', () async {
    await expectLater(
      preparePhoto(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });
}
