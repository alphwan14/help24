import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

/// Listing photos are uploaded at up to 1200 px (post_screen.dart). A card
/// shows them as a 72 dp square, so decoding the original costs about 5.8 MB of
/// memory per photo for a thumbnail. Feed thumbnails are decoded at this width
/// instead: about 0.5 MB each, still sharp at 72 dp on a 3.5x screen with
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
