import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

/// Listing photos are uploaded at up to 1200 px (post_screen.dart). A card
/// shows them as a 96 dp square, so decoding the original costs about 5.8 MB of
/// memory per photo for a thumbnail. Feed thumbnails are decoded at this width
/// instead: about 0.5 MB each, sharp at 96 dp on a 3.5x screen with
/// BoxFit.cover (a 16:9 photo decodes to 384 x 216).
///
/// Width only, so the photo keeps its shape and cover-cropping stays correct.
const int kFeedThumbDecodeWidth = 384;

/// The image provider for a feed thumbnail. The card ([CachedNetworkImage] with
/// `memCacheWidth: kFeedThumbDecodeWidth`) builds exactly this key, so a
/// thumbnail warmed here is the one the card paints, with no second decode.
/// Warm and paint through the same size or the warm-up is wasted.
ImageProvider feedThumbProvider(String url) =>
    ResizeImage.resizeIfNeeded(kFeedThumbDecodeWidth, null, CachedNetworkImageProvider(url));

final RegExp _postPhoto = RegExp(
  r'^(.*/storage/v1/object/public/post-images/posts/[^/?#]+?)\.(jpe?g|png|gif|webp)$',
  caseSensitive: false,
);

/// Where the small JPEG made at upload lives (utils/image_thumbnail.dart):
/// beside the photo, `posts/<name>.thumb.jpg`. Null for anything that is not a
/// post photo in the post-images bucket, or is already a thumbnail.
String? feedThumbUrl(String photoUrl) {
  if (photoUrl.endsWith('.thumb.jpg')) return null;
  final m = _postPhoto.firstMatch(photoUrl);
  return m == null ? null : '${m.group(1)}.thumb.jpg';
}

/// Thumbnails that turned out not to exist this session. Posts from before
/// 1.0.10 have none; remembering the miss means each costs one failed request
/// per session, not one every time its card scrolls into view.
final Set<String> _missingThumbs = <String>{};

/// The URL a feed card should load for [photoUrl]: its thumbnail, unless the
/// photo has none (or it was found missing), then the photo itself.
String feedCardImageUrl(String photoUrl) {
  final thumb = feedThumbUrl(photoUrl);
  return thumb == null || _missingThumbs.contains(thumb) ? photoUrl : thumb;
}

/// Record that [thumbUrl] does not exist, so cards go straight to the photo.
void markFeedThumbMissing(String thumbUrl) => _missingThumbs.add(thumbUrl);

@visibleForTesting
void resetFeedThumbMemory() => _missingThumbs.clear();

/// Decode the card image for [photoUrl] into the image cache, at the card's
/// size. When the thumbnail is missing, notes it and warms the photo instead,
/// so the card does not wait on a second round trip. Completes when the image
/// is ready or definitely failed; never throws.
Future<void> warmFeedCardImage(String photoUrl) async {
  final first = feedCardImageUrl(photoUrl);
  final ok = await _resolve(first);
  if (!ok && first != photoUrl) {
    markFeedThumbMissing(first);
    await _resolve(photoUrl);
  }
}

Future<bool> _resolve(String url) {
  final done = Completer<bool>();
  late final ImageStreamListener listener;
  final ImageStream stream;
  try {
    stream = feedThumbProvider(url).resolve(ImageConfiguration.empty);
  } catch (_) {
    return Future.value(false);
  }
  void finish(bool ok) {
    if (done.isCompleted) return;
    done.complete(ok);
    stream.removeListener(listener);
  }

  listener = ImageStreamListener((_, __) => finish(true), onError: (_, __) => finish(false));
  stream.addListener(listener);
  return done.future;
}
