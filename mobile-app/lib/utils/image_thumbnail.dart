import 'package:flutter/foundation.dart';

import 'thumbnail_codec.dart';

export 'thumbnail_codec.dart' show kThumbShortSide, kThumbQuality, makeThumbnailSync;

/// The feed card's thumbnail for an uploaded photo (see thumbnail_codec.dart),
/// or null when the bytes are not a decodable image.
///
/// Runs on a background isolate: decoding a 1200 px photo takes a few hundred
/// milliseconds in pure Dart, which must not stall the post screen.
Future<Uint8List?> makeThumbnail(Uint8List bytes) => compute(makeThumbnailSync, bytes);
