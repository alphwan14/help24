import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/utils/image_thumbnail.dart';
import 'package:image/image.dart' as img;

Uint8List _png(int w, int h, {bool transparent = false}) {
  final image = img.Image(width: w, height: h, numChannels: transparent ? 4 : 3);
  img.fill(image, color: transparent ? img.ColorRgba8(0, 0, 0, 0) : img.ColorRgb8(200, 120, 40));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  test('an upload-sized photo becomes a small JPEG with its shorter side at 320', () {
    final source = _png(1200, 900);
    final thumb = makeThumbnailSync(source)!;
    final decoded = img.decodeJpg(thumb)!;
    expect(decoded.height, kThumbShortSide);
    expect(decoded.width, 427, reason: 'the shape is kept: 1200 x 900 scales to 427 x 320');
    expect(thumb.length, lessThan(source.length));
    expect(thumb.length, lessThan(40 * 1024));
  });

  test('a portrait photo is scaled by its width', () {
    final decoded = img.decodeJpg(makeThumbnailSync(_png(900, 1200))!)!;
    expect(decoded.width, kThumbShortSide);
    expect(decoded.height, 427);
  });

  test('a photo already smaller than a thumbnail is not enlarged', () {
    final decoded = img.decodeJpg(makeThumbnailSync(_png(200, 150))!)!;
    expect(decoded.width, 200);
    expect(decoded.height, 150);
  });

  test('transparency becomes white, not black', () {
    final decoded = img.decodeJpg(makeThumbnailSync(_png(400, 400, transparent: true))!)!;
    final p = decoded.getPixel(200, 200);
    expect(p.r, greaterThan(240));
    expect(p.g, greaterThan(240));
    expect(p.b, greaterThan(240));
  });

  test('bytes that are not an image give no thumbnail, not an error', () {
    expect(makeThumbnailSync(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });
}
