import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/config/supabase_config.dart';
import 'package:help24/models/remote_config.dart';
import 'package:help24/services/remote_config_service.dart';
import 'package:help24/utils/feed_images.dart';
import 'package:help24/utils/photo_urls.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Public photos are shown through img.help24.co.ke while App controls'
/// "Photos through Cloudflare" switch is on, and straight from Supabase when it
/// is off. Stored URLs never change.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const public = '${SupabaseConfig.supabaseUrl}/storage/v1/object/public';
  const img = 'https://img.help24.co.ke';
  const photo = '$public/post-images/posts/0b5c2d1e-4f3a-4b2c-9d8e-7f6a5b4c3d2e.jpg';
  const thumb = '$public/post-images/posts/0b5c2d1e-4f3a-4b2c-9d8e-7f6a5b4c3d2e.thumb.jpg';
  const avatar = '$public/profiles/k4DZSMyRNRNMRpXM0SypV5v6IHo2/avatar.jpg?t=1731234567890';

  final service = RemoteConfigService.instance;

  RemoteConfig withImageCdn(bool on) => RemoteConfig.fromJson({
        'ops': {
          'kill_switches': {'image_cdn': on},
        },
      });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Help24',
      packageName: 'co.ke.help24',
      version: '1.0.12',
      buildNumber: '13',
      buildSignature: '',
    );
    service.resetForTest();
    resetFeedThumbMemory();
  });

  group('switch on', () {
    test('post photos, thumbnails and avatars load through img.help24.co.ke', () {
      expect(displayPhotoUrl(photo), '$img/post-images/posts/0b5c2d1e-4f3a-4b2c-9d8e-7f6a5b4c3d2e.jpg');
      expect(displayPhotoUrl(thumb), '$img/post-images/posts/0b5c2d1e-4f3a-4b2c-9d8e-7f6a5b4c3d2e.thumb.jpg');
      expect(displayPhotoUrl('$public/post-images/avatars/u1.png'), '$img/post-images/avatars/u1.png');
    });

    test("an avatar keeps its ?t= cache buster, so a new photo is a new address", () {
      expect(displayPhotoUrl(avatar), '$img/profiles/k4DZSMyRNRNMRpXM0SypV5v6IHo2/avatar.jpg?t=1731234567890');
    });

    test('on by default: a fresh install with no config uses the Worker', () {
      expect(service.imageCdnEnabled, isTrue);
      expect(displayPhotoUrl(photo), startsWith(img));
    });

    test('a feed card loads the thumbnail through the Worker, then the photo once it is missing', () {
      final card = feedCardImageUrl(photo);
      expect(card, displayPhotoUrl(thumb));
      markFeedThumbMissing(card);
      expect(feedCardImageUrl(photo), displayPhotoUrl(photo));
    });
  });

  group('never rewritten (the Worker would refuse it)', () {
    for (final url in [
      // Private buckets: never public, and never sent to img.help24.co.ke.
      '$public/chat-attachments/c/u/m.jpg',
      '$public/dispute-evidence/d/e.jpg',
      '$public/provider-verifications/u/id.jpg',
      '$public/support-attachments/t/p.jpg',
      // Private files by signed link.
      '${SupabaseConfig.supabaseUrl}/storage/v1/object/sign/chat-attachments/c/u/m.jpg?token=abc',
      // Old public chat files, and the diagnostic folder.
      '$public/post-images/chat_attachments/c/f.jpg',
      '$public/post-images/test/probe.png',
      // Not a photo, or a query the Worker would drop.
      '$public/post-images/posts/0b5c2d1e-4f3a-4b2c-9d8e-7f6a5b4c3d2e.pdf',
      '$public/post-images/posts/0b5c2d1e-4f3a-4b2c-9d8e-7f6a5b4c3d2e.svg',
      '$photo?download=1',
      '$public/profiles/u/avatar.jpg?t=abc',
      '$public/post-images/posts/../../chat-attachments/x.jpg',
      // Names outside the Worker's rules: not a uuid, not avatar.jpg, folder case.
      '$public/post-images/posts/not-a-uuid.jpg',
      '$public/profiles/k4DZSMyRNRNMRpXM0SypV5v6IHo2/banner.png',
      '$public/Post-Images/posts/0b5c2d1e-4f3a-4b2c-9d8e-7f6a5b4c3d2e.jpg',
      // Another project, another host, nothing at all.
      'https://otherref.supabase.co/storage/v1/object/public/post-images/posts/a.jpg',
      'https://lh3.googleusercontent.com/a/photo.jpg',
      'https://files.help24.co.ke/d/0b5c2d1e-4f3a-4b2c-9d8e-7f6a5b4c3d2e',
      '',
    ]) {
      test(url.isEmpty ? '(empty)' : url, () => expect(displayPhotoUrl(url), url));
    }
  });

  group('switch off', () {
    test('every photo goes straight back to its stored URL', () {
      service.resetForTest(config: withImageCdn(false));
      expect(service.imageCdnEnabled, isFalse);
      expect(displayPhotoUrl(photo), photo);
      expect(displayPhotoUrl(thumb), thumb);
      expect(displayPhotoUrl(avatar), avatar);
      expect(feedCardImageUrl(photo), thumb, reason: 'the card falls back to the direct thumbnail');
    });

    test('an explicit viaCdn wins over the switch', () {
      expect(displayPhotoUrl(photo, viaCdn: false), photo);
      service.resetForTest(config: withImageCdn(false));
      expect(displayPhotoUrl(photo, viaCdn: true), startsWith(img));
    });

    test('switching off in App controls reaches the app on its next refresh', () async {
      final served = {
        'ops': {
          'kill_switches': {
            'payments': true,
            'promotions': true,
            'posting': true,
            'applications': true,
            'image_cdn': false,
          },
        },
      };
      service.resetForTest(
        transport: MockClient((_) async => http.Response(jsonEncode({'version': 'v2', 'config': served}), 200)),
      );
      await service.warmUp();
      expect(displayPhotoUrl(photo), startsWith(img), reason: 'on until the document says otherwise');

      await service.refresh();

      expect(service.imageCdnEnabled, isFalse);
      expect(displayPhotoUrl(photo), photo);
    });

    test('a wrong-typed value keeps the default rather than breaking photos', () {
      service.resetForTest(
        config: RemoteConfig.fromJson({
          'ops': {
            'kill_switches': {'image_cdn': 'false'},
          },
        }),
      );
      expect(service.imageCdnEnabled, isTrue);
    });
  });
}
