import '../config/supabase_config.dart';
import '../services/remote_config_service.dart';

/// Where a public photo is fetched from when it is shown.
///
/// Post photos, their thumbnails and avatars are stored as Supabase Storage
/// URLs (`…supabase.co/storage/v1/object/public/<bucket>/<path>`). Shown, they
/// load through `img.help24.co.ke` instead: a Cloudflare Worker
/// (workers/help24-img) that fetches each file from Supabase once and serves it
/// from Cloudflare's edge, so a phone in Kenya does not wait on Dublin for
/// every photo.
///
/// Stored URLs never change. This runs at display time only, and only while
/// App controls' "Photos through Cloudflare" switch (`image_cdn`) is on; off,
/// every photo goes straight back to its stored URL.
///
/// Rewritten only for what the Worker serves (workers/help24-img/src/policy.js):
/// post photos and thumbnails, and avatars. Anything else, including a link
/// with a query other than the avatar's `?t=` cache buster, stays direct, so a
/// URL the Worker would refuse is never sent to it.
///
/// Warm-ups must pass through here too: an image cached under one URL is not
/// found under the other.
String displayPhotoUrl(String url, {bool? viaCdn}) {
  if (!(viaCdn ?? RemoteConfigService.instance.imageCdnEnabled)) return url;
  if (!url.startsWith(_publicPrefix)) return url;
  final rest = url.substring(_publicPrefix.length);
  if (!_served.hasMatch(rest)) return url;
  return '$photoHost/$rest';
}

/// The Worker's address.
const String photoHost = 'https://img.help24.co.ke';

const String _publicPrefix = '${SupabaseConfig.supabaseUrl}/storage/v1/object/public/';

/// `post-images/posts/<name>`, `post-images/avatars/<name>` or
/// `profiles/<uid>/<name>`, an image extension, and at most `?t=<digits>`.
final RegExp _served = RegExp(
  r'^(post-images/(posts|avatars)/[A-Za-z0-9_-][A-Za-z0-9._-]*|profiles/[A-Za-z0-9_-]+/[A-Za-z0-9_-][A-Za-z0-9._-]*)'
  r'\.(jpe?g|png|gif|webp)(\?t=\d{1,20})?$',
  caseSensitive: false,
);
