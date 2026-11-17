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

/// Exactly the Worker's RULES (workers/help24-img/src/policy.js), so nothing
/// rewritten here is refused there: `post-images/posts/<uuid>.<ext>` and
/// `<uuid>.thumb.jpg`, `post-images/avatars/<uid>.<ext>` and
/// `profiles/<uid>/avatar.jpg`, then at most `?t=<digits>`. Folder names are
/// exact; the hex and the extension may be any case.
final RegExp _served = () {
  const hex = '[0-9a-fA-F]';
  const uuid = '$hex{8}-$hex{4}-$hex{4}-$hex{4}-$hex{12}';
  const uid = '[A-Za-z0-9_-]{1,128}';
  const ext = '(?:[jJ][pP][gG]|[jJ][pP][eE][gG]|[pP][nN][gG]|[gG][iI][fF]|[wW][eE][bB][pP])';
  return RegExp('^(?:post-images/posts/$uuid\\.$ext'
      '|post-images/posts/$uuid\\.thumb\\.jpg'
      '|post-images/avatars/$uid\\.$ext'
      '|profiles/$uid/avatar\\.jpg)'
      r'(?:\?t=\d{1,20})?$');
}();
