import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/feed_pager.dart';
import 'package:help24/utils/feed_images.dart';

void main() {
  const url = 'https://example.com/storage/v1/object/public/post-images/posts/a.jpg';

  test('a feed thumbnail decodes at the thumbnail width, not the photo size', () {
    final provider = feedThumbProvider(url);
    expect(provider, isA<ResizeImage>());
    final resize = provider as ResizeImage;
    expect(resize.width, kFeedThumbDecodeWidth);
    expect(resize.height, isNull, reason: 'width only keeps the photo shape for BoxFit.cover');
    expect(resize.imageProvider, CachedNetworkImageProvider(url));
  });

  testWidgets('the card paints the same image key the feed warms', (tester) async {
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 72,
        height: 72,
        child: CachedNetworkImage(imageUrl: url, memCacheWidth: kFeedThumbDecodeWidth),
      ),
    ));
    final images = tester.widgetList<Image>(find.byType(Image)).map((i) => i.image).toList();
    expect(images, contains(feedThumbProvider(url)),
        reason: 'a different key means the warm-up decodes a copy the card never uses');
  });

  test('Discover pages 30 at a time', () {
    expect(FeedPager.pageSize, 30);
  });

  group('upload-time thumbnails', () {
    const base = 'https://x.supabase.co/storage/v1/object/public/post-images/posts';
    setUp(resetFeedThumbMemory);

    test('a post photo has its thumbnail beside it, whatever its type', () {
      for (final ext in ['jpg', 'jpeg', 'png', 'webp', 'gif', 'PNG']) {
        expect(feedThumbUrl('$base/abc-123.$ext'), '$base/abc-123.thumb.jpg', reason: ext);
      }
    });

    test('anything else has no thumbnail', () {
      expect(feedThumbUrl('$base/abc.thumb.jpg'), isNull, reason: 'already a thumbnail');
      expect(feedThumbUrl('https://x.supabase.co/storage/v1/object/public/profiles/u/avatar.jpg'), isNull);
      expect(feedThumbUrl('https://example.com/a.jpg'), isNull);
      expect(feedThumbUrl(''), isNull);
    });

    test('a card loads the thumbnail, and the photo once the thumbnail is known missing', () {
      const photo = '$base/old-post.png';
      expect(feedCardImageUrl(photo), '$base/old-post.thumb.jpg');
      markFeedThumbMissing('$base/old-post.thumb.jpg');
      expect(feedCardImageUrl(photo), photo,
          reason: 'a post from before 1.0.10 costs one failed request per session, not one per scroll');
      expect(feedCardImageUrl('$base/new-post.jpg'), '$base/new-post.thumb.jpg');
    });
  });
}
