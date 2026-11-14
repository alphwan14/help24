import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../models/support_thread.dart';
import 'session_scope.dart';

/// Message Help24 photos on this phone: each is downloaded once and then
/// opens from disk.
///
/// The backend shows a stored photo as a short-lived signed link, and mints a
/// new one every time the thread loads, so a cache keyed by URL never hits:
/// every open downloaded every photo again (the thread sat on grey boxes on
/// mobile data). Here the key is the message and the photo's place in it,
/// which never change.
///
/// It is its own cache, not the chat one: chat photos come from the files host
/// with the user's token attached, and that cache refuses any other host. A
/// signed link carries its own permission, so this one needs no token. Like
/// the chat cache it is emptied at sign-out ([SupportPhotoScope]): the next
/// account on this phone must not find the last one's photos.
class SupportPhotoCache {
  SupportPhotoCache._();

  static const String key = 'help24SupportPhotos';

  static BaseCacheManager? _instance;

  static BaseCacheManager get instance => _instance ??= _SupportImageCacheManager();

  @visibleForTesting
  static set instanceForTest(BaseCacheManager? manager) => _instance = manager;

  /// The cache key of photo [index] on message [messageId].
  static String keyFor(String messageId, int index) => 'support/$messageId/$index';

  /// Put the photos the member just sent into the cache under their stored
  /// message, so their own bubble never downloads what this phone already has.
  static Future<void> remember({
    required String messageId,
    required List<SupportAttachment> stored,
    required List<SupportPhoto> local,
  }) async {
    if (messageId.isEmpty) return;
    for (var i = 0; i < stored.length && i < local.length; i++) {
      try {
        await write(
          keyFor(messageId, i),
          stored[i].url,
          local[i].bytes,
          switch (local[i].mime) {
            'image/png' => 'png',
            'image/webp' => 'webp',
            _ => 'jpg',
          },
        );
      } catch (e) {
        // Only a missed shortcut: the photo downloads on the next open instead.
        debugPrint('[SUPPORT] photo cache write failed: ${e.runtimeType}');
      }
    }
  }

  /// Stores one photo's bytes under [key]. Replaced in tests.
  @visibleForTesting
  static Future<void> Function(String key, String url, Uint8List bytes, String extension) write =
      (key, url, bytes, extension) => instance.putFile(url, bytes, key: key, fileExtension: extension);

  static Future<void> clear() async {
    try {
      await instance.emptyCache();
    } catch (e) {
      debugPrint('[SUPPORT] photo cache clear failed: ${e.runtimeType}');
    }
  }
}

class _SupportImageCacheManager extends CacheManager with ImageCacheManager {
  _SupportImageCacheManager()
      : super(Config(
          SupportPhotoCache.key,
          stalePeriod: const Duration(days: 30),
          maxNrOfCacheObjects: 200,
        ));
}

/// Empties the Message Help24 photo cache when a session ends.
class SupportPhotoScope implements SessionScoped {
  const SupportPhotoScope();

  @override
  void resetForSignOut() => unawaited(SupportPhotoCache.clear());
}
