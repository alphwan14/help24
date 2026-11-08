import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// The small JPEG a feed card shows instead of the full photo. Pure Dart, with
/// no Flutter import, so the app (utils/image_thumbnail.dart) and the one-off
/// backfill (tool/backfill_post_thumbnails.dart) make byte-for-byte the same
/// thumbnail.
///
/// Photos are uploaded at up to 1200 px (about 150 to 250 KB, more for PNG
/// screenshots). A card shows them as a 72 dp square, so the feed downloaded
/// roughly ten times the pixels it could display. The thumbnail keeps the
/// photo's shape with its SHORTER side at [kThumbShortSide]: a 72 dp
/// cover-cropped square needs at most about 250 px on a 3.5x screen, and 320
/// leaves room. JPEG at [kThumbQuality] is about 20 to 30 KB.
const int kThumbShortSide = 320;
const int kThumbQuality = 75;

/// The thumbnail for [bytes], or null when they are not a decodable image.
Uint8List? makeThumbnailSync(Uint8List bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;

  // Phone cameras record rotation in EXIF rather than in the pixels.
  var image = img.bakeOrientation(decoded);

  final shortSide = math.min(image.width, image.height);
  if (shortSide > kThumbShortSide) {
    image = image.width <= image.height
        ? img.copyResize(image, width: kThumbShortSide, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: kThumbShortSide, interpolation: img.Interpolation.average);
  }

  // JPEG has no transparency: a transparent PNG would turn black. Put it on
  // white, as the card shows it.
  if (image.hasAlpha) {
    final background = img.Image(width: image.width, height: image.height);
    img.fill(background, color: img.ColorRgb8(255, 255, 255));
    image = img.compositeImage(background, image);
  }

  return img.encodeJpg(image, quality: kThumbQuality);
}
