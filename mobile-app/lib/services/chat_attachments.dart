import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/post_model.dart';
import 'api_client.dart';
import 'chat_documents.dart';
import 'session_scope.dart';

/// PRIVATE CHAT ATTACHMENTS — every photo and document sent in a conversation.
///
/// WHAT WAS WRONG
/// --------------
/// A chat photo or document was uploaded to the PUBLIC `post-images` bucket
/// and the message stored its permanent public URL. Anyone holding that URL
/// could download the file forever, "delete for everyone" left it online, and
/// the app's own publishable key could LIST every chat's folder — so any
/// conversation's files were enumerable by someone who was never in it.
///
/// WHAT IT IS NOW
/// --------------
/// Files live in the private `chat-attachments` bucket, which nothing on a
/// phone can read. The only way in or out is the files endpoint
/// ([ApiConfig.filesBaseUrl], a Cloudflare Worker) and it is addressed by
/// MESSAGE, never by file:
///
///   PUT  /u/<chat>/<message>   store the file, as a participant of that chat
///   GET  /d/<message>          read it, as a participant, unless deleted
///   POST /links/<message>      a one-time link for opening it in the browser
///
/// The Firebase ID token rides every request (see [Help24ApiClient]). The
/// message row keeps only the object's reference,
/// `chat-attachments/<chat>/<message>.<ext>` — not an address, so it is no use
/// to anyone who reads it.
class ChatAttachments {
  ChatAttachments._();

  /// Largest attachment accepted — the bucket's own limit, and the Worker's.
  /// Checked when a file is PICKED, so one that could never be sent is refused
  /// up front instead of queued.
  static const int maxBytes = 10 * 1024 * 1024;

  /// The types a chat attachment may be, by file extension. Mirrors
  /// `workers/help24-files/src/policy.js` and the bucket's MIME allowlist.
  static const Map<String, String> contentTypes = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  };

  static const String _uuid =
      r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
  static final RegExp _privateRef =
      RegExp('^chat-attachments/($_uuid)/($_uuid)\\.(jpg|png|gif|webp|pdf|doc|docx)\$');

  /// Whether [ref] is the private reference of exactly this message — its
  /// chat, its id. Anything else (a public URL from an older build, another
  /// message's object) is not this message's stored file.
  static bool isPrivateRefFor(
    String? ref, {
    required String chatId,
    required String messageId,
  }) {
    if (ref == null) return false;
    final m = _privateRef.firstMatch(ref);
    return m != null &&
        m.group(1) == chatId.toLowerCase() &&
        m.group(2) == messageId.toLowerCase();
  }

  /// Where a delivered message's attachment is read from.
  static Uri urlFor(String messageId) =>
      Uri.parse('${ApiConfig.filesBaseUrl}/d/${messageId.toLowerCase()}');

  /// The image cache's key for a message's photo. Keyed by message, not by
  /// URL, so the sender's own seeded copy and a later download are one entry.
  static String cacheKeyFor(String messageId) =>
      'chat-attachment:${messageId.toLowerCase()}';

  /// The upload content type for a local file, from its extension; null when
  /// the file is not a type a chat may carry.
  static String? contentTypeForPath(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    return contentTypes[name.substring(dot + 1).toLowerCase()];
  }
}

/// A refusal or failure from the files endpoint. Carries the HTTP status, so
/// `ErrorMapper` (and through it the outbox) reads a 5xx as "try again" and a
/// 4xx as "this cannot be sent as it is".
class ChatAttachmentException implements Exception {
  const ChatAttachmentException(this.statusCode, this.code);

  final int statusCode;

  /// The endpoint's machine-readable code (`NOT_FOUND`, `GONE`, `TOO_LARGE`…).
  final String code;

  /// The message was deleted for everyone; its file is gone with it.
  bool get isGone => statusCode == 410;

  @override
  String toString() => 'ChatAttachmentException($statusCode $code)';

  static ChatAttachmentException fromResponse(int status, String body) {
    var code = 'HTTP_$status';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['code'] is String) code = decoded['code'] as String;
    } catch (_) {
      // Not JSON; the status says enough.
    }
    return ChatAttachmentException(status, code);
  }
}

/// The two requests that need the network: storing a file, and asking for a
/// browser link. Both carry the Firebase ID token through [Help24ApiClient].
class ChatAttachmentApi {
  ChatAttachmentApi._();

  /// Long enough for 10 MB on a slow mobile link. The response only starts
  /// once the whole body is up, so this is a ceiling on the upload itself.
  static const Duration uploadTimeout = Duration(seconds: 120);

  /// The transport. Replaced in tests.
  @visibleForTesting
  static Future<http.StreamedResponse> Function(http.BaseRequest, Duration) send =
      api.sendWithTimeout;

  /// Store [localPath] as the attachment of message [messageId] in [chatId]
  /// and return the reference the message row must carry.
  ///
  /// Safe to repeat: the object is named by the message id and can never be
  /// overwritten, so a retry after an upload that already landed is answered
  /// "already stored" with the same reference — one file, however many tries.
  static Future<String> upload({
    required String localPath,
    required String chatId,
    required String messageId,
  }) async {
    final type = ChatAttachments.contentTypeForPath(localPath);
    if (type == null) throw const ChatAttachmentException(415, 'UNSUPPORTED_TYPE');
    final bytes = await File(localPath).readAsBytes();
    if (bytes.isEmpty) throw const ChatAttachmentException(400, 'EMPTY');
    if (bytes.length > ChatAttachments.maxBytes) {
      throw const ChatAttachmentException(413, 'TOO_LARGE');
    }

    final id = messageId.toLowerCase();
    if (ChatUploads.isCancelled(id)) throw const ChatUploadCancelled();
    final request = _ProgressRequest(
      'PUT',
      Uri.parse('${ApiConfig.filesBaseUrl}/u/${chatId.toLowerCase()}/$id'),
      onProgress: (p) => ChatUploads._report(id, p),
      isCancelled: () => ChatUploads.isCancelled(id),
    )
      ..headers['content-type'] = type
      ..bodyBytes = bytes;
    ChatUploads._report(id, 0);
    final http.Response response;
    try {
      response = await http.Response.fromStream(await send(request, uploadTimeout));
    } catch (_) {
      if (ChatUploads.isCancelled(id)) throw const ChatUploadCancelled();
      rethrow;
    } finally {
      ChatUploads._report(id, null);
    }

    if (response.statusCode == 200 || response.statusCode == 201) {
      String? ref;
      try {
        ref = (jsonDecode(response.body) as Map)['ref'] as String?;
      } catch (_) {
        ref = null;
      }
      if (!ChatAttachments.isPrivateRefFor(ref, chatId: chatId, messageId: messageId)) {
        throw const ChatAttachmentException(502, 'BAD_REFERENCE');
      }
      debugPrint('[ATTACHMENT] ${response.statusCode == 201 ? 'stored' : 'already stored'} '
          '${messageId.substring(0, 8)} (${bytes.length} B)');
      return ref!;
    }
    throw ChatAttachmentException.fromResponse(response.statusCode, response.body);
  }

  /// A one-time, two-minute link that opens [messageId]'s document in the
  /// browser. A browser cannot carry the app's token, so the endpoint issues a
  /// link the browser trades for a cookie scoped to this one document. The
  /// link is on the Help24 host — never a storage address.
  static Future<Uri> browserLink(String messageId) async {
    final request = http.Request(
      'POST',
      Uri.parse('${ApiConfig.filesBaseUrl}/links/${messageId.toLowerCase()}'),
    );
    final response = await http.Response.fromStream(
        await send(request, const Duration(seconds: 30)));
    if (response.statusCode != 200) {
      throw ChatAttachmentException.fromResponse(response.statusCode, response.body);
    }
    final url = Uri.tryParse(((jsonDecode(response.body) as Map)['url'] ?? '').toString());
    final home = Uri.parse(ApiConfig.filesBaseUrl);
    // Only ever hand the browser an address on the files host itself.
    if (url == null ||
        url.scheme != home.scheme ||
        url.host != home.host ||
        url.port != home.port ||
        url.path != '/d/${messageId.toLowerCase()}') {
      throw const ChatAttachmentException(502, 'BAD_LINK');
    }
    return url;
  }
}

/// UPLOADS IN FLIGHT: how far each has got, and the user's "stop".
///
/// Keyed by the id the message will be stored under (the uuid inside its
/// outbox id), so the bubble that shows a queued photo and the upload that
/// carries it name the same thing.
class ChatUploads {
  ChatUploads._();

  static final Map<String, ValueNotifier<double?>> _progress = {};
  static final Set<String> _cancelled = {};

  /// Null when nothing is uploading for [messageId], otherwise 0…1.
  static ValueListenable<double?> progressOf(String messageId) =>
      _progress.putIfAbsent(messageId.toLowerCase(), () => ValueNotifier<double?>(null));

  static void _report(String id, double? value) =>
      (_progress.putIfAbsent(id, () => ValueNotifier<double?>(null))).value = value;

  /// Stop [messageId]'s upload and keep it from being sent. An upload in
  /// flight fails at its next chunk; one not yet started never starts; and
  /// the delivery checks again before writing the message row.
  static void cancel(String messageId) => _cancelled.add(messageId.toLowerCase());

  static bool isCancelled(String messageId) => _cancelled.contains(messageId.toLowerCase());

  @visibleForTesting
  static void resetForTest() {
    _progress.clear();
    _cancelled.clear();
  }
}

/// The user stopped this upload. Not a failure: the message is withdrawn.
class ChatUploadCancelled implements Exception {
  const ChatUploadCancelled();

  @override
  String toString() => 'ChatUploadCancelled';
}

/// A PUT whose body is streamed in chunks, so progress can be reported as the
/// socket takes the bytes and a cancel can stop it part-way.
///
/// Still an [http.Request]: the API client's replay (one retry after an
/// expired token) copies [bodyBytes] into a plain request, which simply
/// uploads without reporting progress.
class _ProgressRequest extends http.Request {
  _ProgressRequest(
    super.method,
    super.url, {
    required this.onProgress,
    required this.isCancelled,
  });

  final void Function(double progress) onProgress;
  final bool Function() isCancelled;

  static const int _chunk = 32 * 1024;

  @override
  http.ByteStream finalize() {
    super.finalize();
    final bytes = bodyBytes;
    final total = bytes.length;
    Stream<List<int>> chunks() async* {
      var sent = 0;
      while (sent < total) {
        if (isCancelled()) throw const ChatUploadCancelled();
        final end = sent + _chunk < total ? sent + _chunk : total;
        yield bytes.sublist(sent, end);
        sent = end;
        onProgress(sent / total);
      }
    }

    return http.ByteStream(chunks());
  }
}

/// The on-device cache of chat photos.
///
/// Its downloads go through [Help24ApiClient], so each one carries the
/// signed-in user's Firebase token and recovers from an expired one the same
/// way every other request does. It is separate from the app's default image
/// cache so it can be emptied at sign-out without touching public marketplace
/// photos — the next account on this phone must not find the last one's
/// conversations on disk.
class ChatAttachmentCache {
  ChatAttachmentCache._();

  static const String key = 'help24ChatAttachments';

  static BaseCacheManager? _instance;

  static BaseCacheManager get instance => _instance ??= _PrivateImageCacheManager();

  @visibleForTesting
  static set instanceForTest(BaseCacheManager? manager) => _instance = manager;

  /// Put a photo the sender already has on this phone into the cache under its
  /// message, so their own bubble never downloads what they just uploaded.
  static Future<void> remember({
    required String messageId,
    required String localPath,
  }) async {
    final bytes = await File(localPath).readAsBytes();
    final ext = localPath.split('.').last.toLowerCase();
    await instance.putFile(
      ChatAttachments.urlFor(messageId).toString(),
      bytes,
      key: ChatAttachments.cacheKeyFor(messageId),
      fileExtension: ChatAttachments.contentTypes.containsKey(ext) ? ext : 'jpg',
    );
  }

  static Future<void> clear() async {
    _evicted.clear();
    try {
      await instance.emptyCache();
    } catch (e) {
      debugPrint('[ATTACHMENT] cache clear failed: $e');
    }
    final documents = await ChatDocuments.clearAll();
    debugPrint('[ATTACHMENT] private caches cleared (documents removed: $documents)');
  }

  // ── Deleted for everyone ─────────────────────────────────────────────────
  //
  // Once a photo or document is on the phone, the files endpoint refusing it
  // (410) no longer matters — the local copy would still open. So when a
  // deletion reaches this device, by realtime, by a fresh page, from the
  // thread cache or by the user's own action, every local copy of that
  // message's attachment is removed, and the message is remembered for the
  // session so nothing fetches it again.

  static final Set<String> _evicted = {};

  /// True when [messageId]'s attachment was deleted for everyone this session.
  static bool isEvicted(String messageId) => _evicted.contains(messageId.toLowerCase());

  /// Removes a cached photo, on disk and from the decoded-image memory cache.
  @visibleForTesting
  static Future<void> Function(String messageId) evictPhoto = (id) async {
    final key = ChatAttachments.cacheKeyFor(id);
    final onDisk = await instance.getFileFromCache(key) != null;
    await instance.removeFile(key);
    final inMemory = await evictDecodedPhoto(id);
    if (onDisk || inMemory) {
      debugPrint('[ATTACHMENT] ${id.substring(0, 8)} photo evicted from the private cache '
          '(disk: $onDisk, memory: $inMemory)');
    }
  };

  /// Drops [messageId]'s decoded photo from the in-memory image cache.
  ///
  /// Not `CachedNetworkImage.evictFromCache`: that probes with a provider
  /// built from the URL alone, and provider equality is `cacheKey ?? url`, so
  /// it never matches a chat photo — every one is drawn keyed by message.
  @visibleForTesting
  static Future<bool> evictDecodedPhoto(String messageId) =>
      CachedNetworkImageProvider(
        ChatAttachments.urlFor(messageId).toString(),
        cacheKey: ChatAttachments.cacheKeyFor(messageId),
      ).evict();

  /// Remove every local copy of [messageId]'s attachment. Idempotent.
  static Future<void> evict(String messageId) async {
    final id = messageId.toLowerCase();
    _evicted.add(id);
    try {
      await evictPhoto(id);
    } catch (e) {
      debugPrint('[ATTACHMENT] photo eviction failed: ${e.runtimeType}');
    }
    await ChatDocuments.evict(id);
  }

  /// For every message in [messages] that was deleted for everyone and
  /// carried a photo or a document, remove its local copies — once per
  /// session. Anything else, and every other message's files, are untouched.
  static void evictDeleted(Iterable<Message> messages) {
    for (final m in messages) {
      if (!m.deletedForEveryone || !(m.isImage || m.isFile)) continue;
      final id = m.id.toLowerCase();
      if (_evicted.contains(id) || !_messageId.hasMatch(id)) continue;
      debugPrint('[ATTACHMENT] ${id.substring(0, 8)} deleted for everyone — removing local copies');
      unawaited(evict(id));
    }
  }

  static final RegExp _messageId =
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  @visibleForTesting
  static void resetEvictedForTest() => _evicted.clear();
}

class _PrivateImageCacheManager extends CacheManager with ImageCacheManager {
  _PrivateImageCacheManager()
      : super(Config(
          ChatAttachmentCache.key,
          stalePeriod: const Duration(days: 30),
          maxNrOfCacheObjects: 400,
          fileService: HttpFileService(httpClient: FilesHostClient(api)),
        ));
}

/// [Help24ApiClient] attaches the user's Firebase token to whatever it sends.
/// The private image cache only ever needs the files host, so its client
/// refuses anything else — a future caller handing this cache some other URL
/// cannot carry the token there.
@visibleForTesting
class FilesHostClient extends http.BaseClient {
  FilesHostClient(this._inner);

  final http.Client _inner;
  static final Uri _home = Uri.parse(ApiConfig.filesBaseUrl);

  static bool allows(Uri url) =>
      url.scheme == _home.scheme && url.host == _home.host && url.port == _home.port;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!allows(request.url)) {
      return Future.error(ArgumentError('the chat attachment cache only fetches from the files host'));
    }
    return _inner.send(request);
  }
}

/// Empties the private photo and document caches when a session ends.
class ChatAttachmentScope implements SessionScoped {
  const ChatAttachmentScope();

  @override
  void resetForSignOut() => unawaited(ChatAttachmentCache.clear());
}
