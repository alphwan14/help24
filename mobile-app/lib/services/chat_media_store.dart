import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'chat_attachments.dart';
import 'chat_store.dart';

/// CHAT MEDIA ON DISK — avatars, photo thumbnails and map snapshots.
///
/// WHY NOT THE IMAGE CACHE
/// -----------------------
/// Avatars used to live in the app's default image cache: keyed by URL, shared
/// with every marketplace photo, capped at 200 files and evicted after 30 days.
/// Scrolling Discover was enough to push a chat partner's face out, and the
/// next offline launch drew a blank circle. The photos in a thread sat in a
/// 400-file cache with the same 30-day rule.
///
/// Here, each file is keyed by WHO or WHAT it shows — a user id plus a version,
/// a message id, a coordinate — never by a URL (a signed URL changes on every
/// request, so a cache keyed by one always misses). Files are small: avatars
/// are 128 px, thumbnails 256 px. Nothing here is evicted while the chat
/// exists; the whole folder is deleted at sign-out with the database
/// (`ChatStore.deleteEverything`). Full-size photos stay in
/// `ChatAttachmentCache`, which may evict them — the thumbnail is the copy
/// that is always there.
class ChatMediaStore {
  ChatMediaStore._();

  static const int avatarSize = 128;
  static const int thumbSize = 256;
  static const int mapSnapshotHeight = 264;

  /// The signed-in account whose folder renderers read. Set by `ChatSync`.
  static String activeUid = '';

  /// `<support>/chat_media`, resolved once at startup so renderers can ask
  /// "is there a file?" synchronously inside build.
  static String? _root;

  static Future<void> init() async {
    try {
      _root = (await ChatStore.mediaRoot()).path;
      unawaited(_logUsage());
    } catch (e) {
      debugPrint('[CHAT_MEDIA] init: $e');
    }
  }

  /// One line at startup: what chat media costs on this phone, by kind.
  static Future<void> _logUsage() async {
    final root = _root;
    if (root == null) return;
    final usage = <String, ({int files, int bytes})>{};
    try {
      final dir = Directory(root);
      if (!await dir.exists()) return;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        final segments = entity.uri.pathSegments;
        final kind = segments.length >= 2 ? segments[segments.length - 2] : 'other';
        final prior = usage[kind] ?? (files: 0, bytes: 0);
        usage[kind] = (files: prior.files + 1, bytes: prior.bytes + await entity.length());
      }
    } catch (_) {
      return;
    }
    if (usage.isEmpty) return;
    debugPrint('[CHAT_MEDIA] on disk: ${usage.entries.map((e) => '${e.key} ${e.value.files} files '
        '${(e.value.bytes / 1024).round()}KB').join(', ')}');
  }

  @visibleForTesting
  static void resetForTest() {
    _root = null;
    activeUid = '';
    _known.clear();
  }

  static String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// Files proven to exist this session, so a list of 50 bubbles does not
  /// stat the disk on every rebuild.
  static final Set<String> _known = {};

  static File? _existing(String path) {
    if (_known.contains(path)) return File(path);
    final f = File(path);
    if (f.existsSync()) {
      _known.add(path);
      return f;
    }
    return null;
  }

  /// A stable short version for a photo address: FNV-1a, hex.
  static String versionOf(String url) {
    var hash = 0x811c9dc5;
    for (final unit in url.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  // ── Avatars ────────────────────────────────────────────────────────────────

  static bool _syncingAvatars = false;

  /// Download every chat partner's photo that is not on this phone yet (or
  /// has changed), sequentially. Called after each successful list sync.
  static Future<void> syncAvatars(String uid, {int max = 80}) async {
    if (uid.isEmpty || _syncingAvatars) return;
    _syncingAvatars = true;
    var fetched = 0;
    try {
      final people = await ChatStore.instance.peopleNeedingAvatars(uid);
      final dir = await ChatStore.mediaDirFor(uid, 'avatars');
      for (final p in people) {
        if (fetched >= max) break;
        final url = p.avatarUrl;
        if (url == null || url.isEmpty) continue;
        final version = versionOf(url);
        final current = p.avatarPath;
        if (p.avatarVersion == version && current != null && File(current).existsSync()) {
          continue;
        }
        final bytes = await _download(url);
        if (bytes == null) continue;
        final png = await _downscale(bytes, avatarSize);
        if (png == null) continue;
        final file = File('${dir.path}/${_safe(p.id)}_$version.png');
        await file.writeAsBytes(png, flush: true);
        _known.add(file.path);
        if (current != null && current != file.path) {
          try {
            await File(current).delete();
          } catch (_) {}
          _known.remove(current);
        }
        await ChatStore.instance.setAvatarFile(uid, p.id, path: file.path, version: version);
        fetched++;
      }
      if (fetched > 0) debugPrint('[CHAT_MEDIA] avatars stored: $fetched');
    } catch (e) {
      debugPrint('[CHAT_MEDIA] avatar sync: $e');
    } finally {
      _syncingAvatars = false;
    }
  }

  // ── Photo thumbnails ───────────────────────────────────────────────────────

  static String? _thumbPath(String uid, String messageId) {
    final root = _root;
    if (root == null || uid.isEmpty || messageId.isEmpty) return null;
    return '$root/${_safe(uid)}/thumbs/${_safe(messageId.toLowerCase())}.png';
  }

  /// The thumbnail of [messageId]'s photo, if it is on this phone.
  static File? thumbFor(String messageId) {
    final path = _thumbPath(activeUid, messageId);
    return path == null ? null : _existing(path);
  }

  static bool _thumbing = false;

  /// Make sure the photos in [chatIds] have thumbnails on this phone, newest
  /// first, at most [limit] per call. A photo already in the private image
  /// cache costs no network; the rest are fetched through it.
  static Future<void> ensureThumbs(String uid, List<String> chatIds, {int limit = 40}) async {
    if (uid.isEmpty || chatIds.isEmpty || _thumbing) return;
    _thumbing = true;
    var made = 0;
    try {
      final pending = await ChatStore.instance.imagesWithoutThumbs(uid, chatIds, limit: limit);
      await ChatStore.mediaDirFor(uid, 'thumbs');
      for (final m in pending) {
        final path = _thumbPath(uid, m.id);
        if (path == null) break;
        if (_existing(path) != null) {
          await ChatStore.instance.setThumbPath(uid, m.id, path);
          continue;
        }
        if (ChatAttachmentCache.isEvicted(m.id)) continue;
        try {
          final file = await ChatAttachmentCache.instance.getSingleFile(
            ChatAttachments.urlFor(m.id).toString(),
            key: ChatAttachments.cacheKeyFor(m.id),
          );
          final png = await _downscale(await file.readAsBytes(), thumbSize);
          if (png == null) continue;
          await File(path).writeAsBytes(png, flush: true);
          _known.add(path);
          await ChatStore.instance.setThumbPath(uid, m.id, path);
          made++;
        } catch (e) {
          // Offline, refused (deleted for everyone) or not an image: leave it;
          // the next sync tries again.
          debugPrint('[CHAT_MEDIA] thumb ${shortId(m.id)} skipped: ${e.runtimeType}');
        }
      }
      if (made > 0) debugPrint('[CHAT_MEDIA] thumbnails stored: $made');
    } catch (e) {
      debugPrint('[CHAT_MEDIA] thumbs: $e');
    } finally {
      _thumbing = false;
    }
  }

  /// Remove [messageId]'s thumbnail — the photo was deleted for everyone.
  static Future<void> evictThumb(String messageId) async {
    final path = _thumbPath(activeUid, messageId);
    if (path == null) return;
    _known.remove(path);
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ── Map snapshots ──────────────────────────────────────────────────────────

  /// A location card's map as drawn online, so the card is a map offline too.
  /// Keyed by the pin (5 decimals ≈ 1 m) and the map style (light / night).
  static String? _mapPath(double lat, double lng, String style) {
    final root = _root;
    if (root == null || activeUid.isEmpty) return null;
    final key = '${lat.toStringAsFixed(5)}_${lng.toStringAsFixed(5)}_$style';
    return '$root/${_safe(activeUid)}/maps/${_safe(key)}.png';
  }

  static File? mapSnapshotFor(double lat, double lng, String style) {
    final path = _mapPath(lat, lng, style);
    return path == null ? null : _existing(path);
  }

  /// Keep [png] as the snapshot for this pin — unless it is a blank map (the
  /// tiles had not loaded), which would be worse than no snapshot at all.
  static Future<bool> saveMapSnapshot(
      double lat, double lng, String style, Uint8List png) async {
    final path = _mapPath(lat, lng, style);
    if (path == null) return false;
    if (!await looksDrawn(png)) return false;
    try {
      await ChatStore.mediaDirFor(activeUid, 'maps');
      // The platform view is captured at screen density (~800 px wide on a
      // 3x phone); the card is 132 dp tall, so 2x of that is plenty.
      final scaled = await _downscale(png, mapSnapshotHeight) ?? png;
      await File(path).writeAsBytes(scaled, flush: true);
      _known.add(path);
      return true;
    } catch (e) {
      debugPrint('[CHAT_MEDIA] map snapshot: $e');
      return false;
    }
  }

  /// Whether an image has real content rather than one flat colour or an
  /// empty tile grid: a loaded map has roads, water, parks and labels; a map
  /// waiting for tiles has two or three tones. Counted on a coarse sample.
  static Future<bool> looksDrawn(Uint8List png, {int minColours = 8}) async {
    try {
      final codec = await ui.instantiateImageCodec(png, targetWidth: 48);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      if (data == null) return false;
      final colours = <int>{};
      for (var y = 0; y < h; y += 2) {
        for (var x = 0; x < w; x += 2) {
          final i = (y * w + x) * 4;
          // 4 bits per channel: anti-aliasing noise does not count as content.
          final c = ((data.getUint8(i) >> 4) << 8) |
              ((data.getUint8(i + 1) >> 4) << 4) |
              (data.getUint8(i + 2) >> 4);
          colours.add(c);
          if (colours.length >= minColours) return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ── Plumbing ───────────────────────────────────────────────────────────────

  /// Test seam for avatar downloads.
  @visibleForTesting
  static Future<Uint8List?> Function(String url)? downloadOverride;

  static Future<Uint8List?> _download(String url) async {
    final override = downloadOverride;
    if (override != null) return override(url);
    try {
      final uri = Uri.parse(url);
      if (!uri.hasScheme || !(uri.scheme == 'https' || uri.scheme == 'http')) return null;
      final response = await http.get(uri).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// [bytes] scaled so its SHORT side is [size] (never upscaled), as PNG.
  static Future<Uint8List?> _downscale(Uint8List bytes, int size) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width;
      final h = descriptor.height;
      final shortSide = w < h ? w : h;
      final ui.Codec codec;
      if (shortSide <= size) {
        codec = await descriptor.instantiateCodec();
      } else if (w <= h) {
        codec = await descriptor.instantiateCodec(targetWidth: size);
      } else {
        codec = await descriptor.instantiateCodec(targetHeight: size);
      }
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      descriptor.dispose();
      buffer.dispose();
      return data?.buffer.asUint8List();
    } catch (e) {
      debugPrint('[CHAT_MEDIA] decode: ${e.runtimeType}');
      return null;
    }
  }
}
