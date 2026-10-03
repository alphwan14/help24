import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/post_model.dart';
import 'chat_service_supabase.dart';
import 'storage_service.dart';
import 'supabase_auth_bridge.dart';

/// ONE WAY FOR A QUEUED MESSAGE TO REACH THE SERVER, WHATEVER IT CARRIES.
///
/// WHAT WAS WRONG
/// --------------
/// The outbox could only ever send TEXT. Both of its senders — `ChatScreen`
/// for the open thread and `OutboxStore` for every other — called
/// `sendMessage(content: text)` and nothing else. Photos, documents and places
/// never entered it at all: each picker uploaded or inserted on the spot, and
/// when that failed (always, offline) the user got a snackbar and the photo,
/// the contract or the pin was simply gone. There was no bubble, no queue, and
/// nothing on disk to retry from — the picked file lived in the image/file
/// plugin's cache directory and was referenced only from memory.
///
/// WHAT THIS IS
/// ------------
/// The single delivery step both senders now call, so a queued photo and a
/// queued sentence follow exactly the same lifecycle (queued → sending →
/// delivered, or failed → retry). For an attachment it is two server steps —
/// store the file, then write the message row — and both are made safe to
/// repeat:
///
///   * the upload is named by the message's own id, so a retry after the
///     upload already succeeded is answered "already stored" and reuses it;
///   * the row is inserted under that same id, so a retry after the insert
///     already committed is answered by the primary key and adopts the row.
///
/// Between the two, the uploaded URL is handed back through [onUploaded] for
/// the caller to persist, so an ordinary retry does not even re-upload.
///
/// Nothing here decides authorisation. The insert is still subject to RLS
/// (participants only) and to the Trust & Safety trigger exactly as before —
/// a message sitting in the queue is not proof the user may send it.
class OutboxDelivery {
  OutboxDelivery._();

  /// The server operations. Replaced in tests; production talks to Supabase.
  static OutboxTransport transport = const SupabaseOutboxTransport();

  /// Deliver [message] to [chatId] as [senderId] and return the server's row.
  ///
  /// Throws on any failure; the caller decides what the failure means for the
  /// message's status (see `OutboxStore.statusAfterFailure`). Never deletes or
  /// drops the message itself.
  static Future<Message> deliver({
    required String senderId,
    required String chatId,
    required Message message,
    void Function(Message uploaded)? onUploaded,
  }) async {
    final t = transport;
    final serverId = OutboxIds.serverIdOf(message.id);
    await t.ensureSession();

    final Message confirmed;
    switch (message.type) {
      case 'image':
      case 'file':
        var url = message.attachmentUrl;
        if (url == null || url.isEmpty) {
          final path = message.localPath;
          if (path == null || !await File(path).exists()) {
            throw const OutboxPermanentFailure('attachment file missing');
          }
          url = await t.upload(localPath: path, chatId: chatId, objectId: serverId);
          onUploaded?.call(message.copyWith(attachmentUrl: url));
        }
        confirmed = await t.sendAttachment(
          chatId: chatId,
          senderId: senderId,
          type: message.type,
          attachmentUrl: url,
          caption: message.text,
          clientMessageId: serverId,
        );
        final local = message.localPath;
        if (local != null) {
          if (message.type == 'image') {
            await t.rememberImage(url: url, localPath: local);
          }
          await OutboxFiles.discard(local);
        }
        break;
      case 'location':
        final lat = message.latitude;
        final lng = message.longitude;
        if (lat == null || lng == null) {
          throw const OutboxPermanentFailure('location without coordinates');
        }
        confirmed = await t.sendLocation(
          chatId: chatId,
          senderId: senderId,
          latitude: lat,
          longitude: lng,
          label: message.text == 'Location' ? null : message.text,
          clientMessageId: serverId,
        );
        break;
      case 'location_request':
        confirmed = await t.sendLocationRequest(
          chatId: chatId,
          senderId: senderId,
          clientMessageId: serverId,
        );
        break;
      case 'text':
        confirmed = await t.sendText(
          chatId: chatId,
          senderId: senderId,
          message: message,
          clientMessageId: serverId,
        );
        break;
      default:
        throw OutboxPermanentFailure('unsupported type ${message.type}');
    }
    return confirmed;
  }
}

/// THE THREAD AS IT SHOULD BE SHOWN: what the server has, plus what is still
/// queued — every message exactly once, oldest first.
///
/// For a brief window a message can be in both lists: its row has arrived by
/// realtime but the sender has not yet removed it from the queue. It used to
/// be matched by "same text, sent by me, within 15 seconds" — which hid the
/// second of two photos sent together, because every captionless photo's text
/// is "Image". The queued id now names the server row exactly, so the match is
/// exact. The text heuristic survives only for text queued by an older build,
/// whose ids carry no row id.
List<Message> mergeOutboxIntoThread(
  List<Message> delivered,
  List<Message> pending,
) {
  final combined = List<Message>.of(delivered);
  final deliveredIds = {for (final m in delivered) m.id};
  for (final p in pending) {
    final serverId = OutboxIds.serverIdOf(p.id);
    final bool alreadyDelivered;
    if (serverId != null) {
      alreadyDelivered = deliveredIds.contains(serverId);
    } else {
      alreadyDelivered = p.type == 'text' &&
          delivered.any((m) =>
              m.isMe &&
              m.text == p.text &&
              m.timestamp.difference(p.timestamp).inSeconds.abs() < 15);
    }
    if (!alreadyDelivered) combined.add(p);
  }
  combined.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return combined;
}

/// A failure no retry can fix — the queued file is gone, or the message is
/// malformed. Marked failed straight away rather than retried on a timer.
class OutboxPermanentFailure implements Exception {
  final String reason;
  const OutboxPermanentFailure(this.reason);

  @override
  String toString() => 'OutboxPermanentFailure: $reason';
}

/// Identity of a message that has not reached the server yet.
///
/// The id is minted ONCE, when the message is composed, and the server row is
/// later inserted under the uuid inside it. That is what lets every retry —
/// after a lost response, a killed process, a reconnect — be recognised as the
/// same message instead of a new one.
class OutboxIds {
  OutboxIds._();

  /// Every unsent message's id starts with this; the thread uses it to tell a
  /// queued bubble from a delivered one.
  static const String prefix = 'pending_';

  static String create() => '$prefix${const Uuid().v4()}';

  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  /// The id the server row is (or will be) stored under, or null for a
  /// message queued by an older build as `pending_<millis>` — those are sent
  /// as before, without an idempotency key, because no row id was ever
  /// promised for them.
  static String? serverIdOf(String pendingId) {
    if (!pendingId.startsWith(prefix)) return null;
    final rest = pendingId.substring(prefix.length);
    return _uuid.hasMatch(rest) ? rest : null;
  }

  static bool isPending(String id) => id.startsWith(prefix);
}

/// App-private copies of attachments waiting to be sent.
///
/// A picked photo or document is NOT kept where the picker left it: image_picker
/// and file_picker write into the app's cache directory, which Android may
/// clear under storage pressure at any time. A queued attachment is a promise
/// to send something later, so it is copied into the application-support
/// directory — durable, private to the app, never synced — and the copy's path
/// is what the outbox persists. The copy is deleted when the message is
/// delivered, and every copy an account still holds is deleted when that
/// account signs out (its queue is purged at the same moment).
class OutboxFiles {
  OutboxFiles._();

  /// Test seam: where the per-account directories live.
  @visibleForTesting
  static Future<Directory> Function()? rootOverride;

  static Future<Directory> _root() async {
    final override = rootOverride;
    if (override != null) return override();
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/chat_outbox');
  }

  static String _safe(String part) =>
      part.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');

  static Future<Directory> _dirFor(String uid) async {
    final dir = Directory('${(await _root()).path}/${_safe(uid)}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// The file extension (without the dot) of [name], or '' when it has none.
  static String extensionOf(String name) {
    final base = name.split(RegExp(r'[\\/]')).last;
    final dot = base.lastIndexOf('.');
    if (dot <= 0 || dot == base.length - 1) return '';
    return base.substring(dot + 1).toLowerCase();
  }

  /// Copy a just-picked file into durable app storage and return the copy's
  /// path. [name] carries the original file name when the source path does not
  /// (content URIs), so the extension — which decides the upload's content
  /// type — survives.
  static Future<String> adopt({
    required String sourcePath,
    required String uid,
    required String messageId,
    String? name,
  }) async {
    final ext = extensionOf(name ?? sourcePath).isNotEmpty
        ? extensionOf(name ?? sourcePath)
        : extensionOf(sourcePath);
    final dir = await _dirFor(uid);
    final target = '${dir.path}/${_safe(messageId)}${ext.isEmpty ? '' : '.$ext'}';
    await File(sourcePath).copy(target);
    return target;
  }

  /// Best-effort delete of one queued copy.
  static Future<void> discard(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('[OUTBOX] could not delete $path: $e');
    }
  }

  /// Delete every queued copy [uid] holds. Called at sign-out, when the queue
  /// that referenced them is purged.
  static Future<void> purgeUser(String uid) async {
    if (uid.isEmpty) return;
    try {
      final dir = Directory('${(await _root()).path}/${_safe(uid)}');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('[OUTBOX] purge failed for $uid: $e');
    }
  }

  /// Delete copies no queued message refers to any more — left behind when a
  /// message for a conversation that did not exist yet was composed and the
  /// app was killed before it could be sent (that queue lives in memory only).
  /// [grace] spares a copy made moments ago for a message still being queued.
  static Future<int> sweep({
    required String uid,
    required Set<String> keep,
    Duration grace = const Duration(hours: 1),
  }) async {
    if (uid.isEmpty) return 0;
    var removed = 0;
    // Matched by file name: every copy lives directly in this account's
    // directory, and a listed path is not spelled like a stored one on every
    // platform (Windows joins with '\', so a path comparison kept nothing).
    final keepNames = {for (final p in keep) _nameOf(p)};
    try {
      final dir = Directory('${(await _root()).path}/${_safe(uid)}');
      if (!await dir.exists()) return 0;
      final cutoff = DateTime.now().subtract(grace);
      await for (final entity in dir.list()) {
        if (entity is! File || keepNames.contains(_nameOf(entity.path))) continue;
        try {
          final modified = await entity.lastModified();
          if (modified.isAfter(cutoff)) continue;
          await entity.delete();
          removed++;
        } on FileSystemException {
          // Delivered (and deleted) between the listing and now — fine.
        }
      }
    } catch (e) {
      debugPrint('[OUTBOX] sweep failed for $uid: $e');
    }
    return removed;
  }

  static String _nameOf(String path) => path.split(RegExp(r'[\\/]')).last;
}

/// The server operations a delivery needs.
abstract class OutboxTransport {
  const OutboxTransport();

  Future<void> ensureSession();

  Future<String> upload({
    required String localPath,
    required String chatId,
    String? objectId,
  });

  Future<Message> sendText({
    required String chatId,
    required String senderId,
    required Message message,
    String? clientMessageId,
  });

  Future<Message> sendAttachment({
    required String chatId,
    required String senderId,
    required String type,
    required String attachmentUrl,
    required String caption,
    String? clientMessageId,
  });

  Future<Message> sendLocation({
    required String chatId,
    required String senderId,
    required double latitude,
    required double longitude,
    String? label,
    String? clientMessageId,
  });

  Future<Message> sendLocationRequest({
    required String chatId,
    required String senderId,
    String? clientMessageId,
  });

  /// Seed the image cache with a photo just delivered, under its server URL,
  /// so the sender's bubble does not re-download what is already on the phone.
  Future<void> rememberImage({required String url, required String localPath});
}

class SupabaseOutboxTransport extends OutboxTransport {
  const SupabaseOutboxTransport();

  @override
  Future<void> ensureSession() => SupabaseAuthBridge.ensureSessionAsync();

  @override
  Future<String> upload({
    required String localPath,
    required String chatId,
    String? objectId,
  }) =>
      StorageService.uploadChatAttachment(XFile(localPath), chatId,
          objectId: objectId);

  @override
  Future<Message> sendText({
    required String chatId,
    required String senderId,
    required Message message,
    String? clientMessageId,
  }) =>
      ChatServiceSupabase.sendMessage(
        chatIdParam: chatId,
        senderId: senderId,
        content: message.text,
        replyToId: message.replyToId,
        replyToSender: message.replyToSender,
        replyToPreview: message.replyToPreview,
        clientMessageId: clientMessageId,
      );

  @override
  Future<Message> sendAttachment({
    required String chatId,
    required String senderId,
    required String type,
    required String attachmentUrl,
    required String caption,
    String? clientMessageId,
  }) =>
      ChatServiceSupabase.sendAttachmentMessage(
        chatIdParam: chatId,
        senderId: senderId,
        type: type,
        attachmentUrl: attachmentUrl,
        caption: caption,
        clientMessageId: clientMessageId,
      );

  @override
  Future<Message> sendLocation({
    required String chatId,
    required String senderId,
    required double latitude,
    required double longitude,
    String? label,
    String? clientMessageId,
  }) =>
      ChatServiceSupabase.sendLocation(
        chatId: chatId,
        senderId: senderId,
        latitude: latitude,
        longitude: longitude,
        label: label,
        clientMessageId: clientMessageId,
      );

  @override
  Future<Message> sendLocationRequest({
    required String chatId,
    required String senderId,
    String? clientMessageId,
  }) =>
      ChatServiceSupabase.sendLocationRequest(
        chatId: chatId,
        senderId: senderId,
        clientMessageId: clientMessageId,
      );

  @override
  Future<void> rememberImage({
    required String url,
    required String localPath,
  }) async {
    try {
      final bytes = await File(localPath).readAsBytes();
      await DefaultCacheManager().putFile(
        url,
        bytes,
        fileExtension: OutboxFiles.extensionOf(localPath).isEmpty
            ? 'jpg'
            : OutboxFiles.extensionOf(localPath),
      );
    } catch (e) {
      // Only a saved download is lost; the bubble fetches the URL instead.
      debugPrint('[OUTBOX] image cache seed failed: $e');
    }
  }
}
