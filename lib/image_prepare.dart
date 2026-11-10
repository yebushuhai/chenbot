import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;

/// Re-encode an image without metadata and apply its EXIF orientation.
/// This is a client-side convenience, not a substitute for server validation.
Future<Uint8List> preparePhoto(Uint8List bytes) => compute(_prepare, bytes);
Uint8List _prepare(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
    throw const FormatException('图片大小不受支持');
  }
  final decoder = image.findDecoderForData(bytes);
  if (decoder is! image.JpegDecoder && decoder is! image.PngDecoder) {
    throw const FormatException('仅支持 JPEG 或 PNG');
  }
  final info = decoder!.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 16000000 ||
      info.numFrames != 1) {
    throw const FormatException('图片尺寸不受支持');
  }
  final decoded = decoder.decode(bytes);
  if (decoded == null) throw const FormatException('无法读取图片');
  final oriented = image.bakeOrientation(decoded);
  final clean = image.Image(
    width: oriented.width,
    height: oriented.height,
    numChannels: 3,
  );
  image.fill(clean, color: image.ColorRgb8(255, 255, 255));
  image.compositeImage(clean, oriented);
  final output = Uint8List.fromList(image.encodeJpg(clean, quality: 85));
  if (output.length > 8 * 1024 * 1024) throw const FormatException('图片压缩后仍然过大');
  return output;
}
