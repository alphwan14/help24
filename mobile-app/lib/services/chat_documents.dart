import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';
import 'chat_attachments.dart';

/// What happened when a document was opened.
enum DocumentOpenResult {
  /// Handed to a viewer app on this phone.
  opened,

  /// The file is on the phone, but no installed app can open its type.
  noViewer,

  /// Not on the phone yet, and there is no connection to fetch it.
  offline,

  /// The message was deleted for everyone.
  gone,

  /// The endpoint has no such file for this person (not a participant, or
  /// the row names nothing it may serve).
  unavailable,

  /// Anything else — a server error, an interrupted or incomplete download.
  failed,
}

/// CHAT DOCUMENTS OPEN LIKE CHAT PHOTOS: DOWNLOADED ONCE, THEN FROM THE PHONE.
///
/// WHY
/// ---
/// A document used to open through a one-time browser link: the app minted a
/// link, Chrome exchanged it for a cookie (a Durable Object burn and a 303),
/// then fetched the file — three network trips with a Supabase read each,
/// every single time, 3–4 s for a tiny PDF and ~9 s for a 9 MB one (measured
/// on the S20+ 2026-10-04). Photos, by contrast, open in ~0.3 s because the
/// app already holds them.
///
/// HOW
/// ---
/// The first open downloads the file through the same authenticated read the
/// photos use — `GET /d/<message>` with the user's own Firebase token, so the
/// files Worker checks participation and deletion exactly as before — into
/// app-private storage. Every later open hands that local copy to a viewer
/// app with no network at all. Nothing here can reach a storage URL or a
/// public address; the only request is to the files host.
///
/// ON DISK
/// -------
/// `<app files>/chat_documents/<message id>/<file name>`. The directory is
/// the cache identity — two documents with the same name never collide —
/// and the file keeps the name it was sent with, so the viewer shows it.
/// A download is written to `.part-*` in that directory and renamed into
/// place only after the whole body arrived and matched its declared length:
/// a file that exists under its real name is complete by construction.
class ChatDocuments {
  ChatDocuments._();

  static const String folder = 'chat_documents';

  /// Total space the document cache may use; the least recently opened
  /// documents are removed above it.
  static const int maxCacheBytes = 100 * 1024 * 1024;

  /// A download that delivers nothing for this long is abandoned.
  static const Duration idleTimeout = Duration(seconds: 30);

  static const Map<String, String> _mimeByExt = {
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  };

  static final RegExp _uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  // ── seams (tests replace these) ──────────────────────────────────────────

  @visibleForTesting
  static Future<Directory> Function()? rootOverride;

  /// The authenticated transport: [Help24ApiClient] attaches the Firebase
  /// token and replays once on TOKEN_EXPIRED, exactly as for photos.
  @visibleForTesting
  static Future<http.StreamedResponse> Function(http.BaseRequest request) send =
      (request) => api.sendWithTimeout(request, const Duration(seconds: 30));

  /// Hands a local file to a viewer app; false when none can open it.
  @visibleForTesting
  static Future<bool> Function(String path, String mimeType) viewer = _openWithAndroid;

  static const MethodChannel _channel = MethodChannel('com.help24.help24/documents');

  // ── state ────────────────────────────────────────────────────────────────

  static final Map<String, ValueNotifier<double?>> _progress = {};
  static final Map<String, Future<File>> _inFlight = {};
  static bool _swept = false;

  /// Download progress for [messageId]'s document: null when idle, -1 while
  /// the size is not yet known, otherwise 0…1. The bubble shows this from the
  /// moment a download starts.
  static ValueListenable<double?> progressOf(String messageId) =>
      _progress.putIfAbsent(messageId.toLowerCase(), () => ValueNotifier<double?>(null));

  static Future<Directory> _root() async {
    final override = rootOverride;
    final base = override != null ? await override() : await getApplicationSupportDirectory();
    return Directory('${base.path}/$folder');
  }

  static Future<Directory?> _dirFor(String messageId) async {
    final id = messageId.toLowerCase();
    if (!_uuid.hasMatch(id)) return null; // never a path from anywhere else
    return Directory('${(await _root()).path}/$id');
  }

  /// The complete, cached copy of [messageId]'s document, or null.
  static Future<File?> cached(String messageId) async {
    await _sweepOnce();
    final dir = await _dirFor(messageId);
    if (dir == null || !await dir.exists()) return null;
    final files = <File>[];
    await for (final e in dir.list()) {
      if (e is File && !_isTemp(e.path)) files.add(e);
    }
    if (files.length != 1 || await files.single.length() == 0) {
      // Nothing, or something that cannot be a finished download: start over.
      if (files.isNotEmpty) await _deleteDir(dir);
      return null;
    }
    return files.single;
  }

  /// Open [messageId]'s document: from the phone when it is there, otherwise
  /// after one authenticated download. Never throws.
  static Future<DocumentOpenResult> open(String messageId) async {
    final id = messageId.toLowerCase();
    if (!_uuid.hasMatch(id)) return DocumentOpenResult.failed;
    if (ChatAttachmentCache.isEvicted(id)) return DocumentOpenResult.gone;

    var file = await cached(id);
    if (file != null) {
      _touch(file);
    } else {
      try {
        // A block body on purpose: `() => _inFlight.remove(id)` would return
        // this very future, and whenComplete waits on what its callback
        // returns — the download would wait on itself forever.
        file = await (_inFlight[id] ??= _download(id).whenComplete(() {
          _inFlight.remove(id);
        }));
      } on ChatAttachmentException catch (e) {
        debugPrint('[DOCUMENT] ${id.substring(0, 8)} download refused: $e');
        if (e.isGone) {
          await ChatAttachmentCache.evict(id);
          return DocumentOpenResult.gone;
        }
        if (e.statusCode == 404) return DocumentOpenResult.unavailable;
        return DocumentOpenResult.failed;
      } catch (e) {
        debugPrint('[DOCUMENT] ${id.substring(0, 8)} download failed: ${e.runtimeType}');
        return _isConnectivity(e) ? DocumentOpenResult.offline : DocumentOpenResult.failed;
      }
    }

    final mime = _mimeByExt[_extOf(file.path)];
    if (mime == null) return DocumentOpenResult.failed;
    try {
      return await viewer(file.path, mime) ? DocumentOpenResult.opened : DocumentOpenResult.noViewer;
    } catch (e) {
      debugPrint('[DOCUMENT] viewer hand-off failed: ${e.runtimeType}');
      return DocumentOpenResult.noViewer;
    }
  }

  static Future<File> _download(String id) async {
    final dir = (await _dirFor(id))!;
    final progress = _progress.putIfAbsent(id, () => ValueNotifier<double?>(null));
    progress.value = -1;
    final tmp = File('${dir.path}/.part-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}');
    try {
      final response = await send(http.Request('GET', ChatAttachments.urlFor(id)));
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString().catchError((_) => '');
        throw ChatAttachmentException.fromResponse(response.statusCode, body);
      }
      final mime = (response.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
      final ext = _mimeByExt.entries.where((e) => e.value == mime).map((e) => e.key).firstOrNull;
      if (ext == null) {
        await response.stream.drain<void>().catchError((_) {});
        throw const ChatAttachmentException(415, 'NOT_A_DOCUMENT');
      }
      final total = int.tryParse(response.headers['content-length'] ?? '');
      if (total != null && total > ChatAttachments.maxBytes) {
        await response.stream.drain<void>().catchError((_) {});
        throw const ChatAttachmentException(413, 'TOO_LARGE');
      }
      final name = fileNameFor(response.headers['content-disposition'], ext);

      await dir.create(recursive: true);
      final sink = tmp.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream.timeout(idleTimeout)) {
          received += chunk.length;
          if (received > ChatAttachments.maxBytes) {
            throw const ChatAttachmentException(413, 'TOO_LARGE');
          }
          sink.add(chunk);
          if (total != null && total > 0) progress.value = received / total;
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (received == 0 || (total != null && received != total)) {
        throw const ChatAttachmentException(502, 'INCOMPLETE');
      }

      // Only now does the document get its real name. A rename within one
      // directory is atomic, so a reader sees either nothing or all of it.
      final target = File('${dir.path}/$name');
      await for (final e in dir.list()) {
        if (e is File && e.path != tmp.path && !_isTemp(e.path)) await e.delete();
      }
      final done = await tmp.rename(target.path);
      if (ChatAttachmentCache.isEvicted(id)) {
        // Deleted for everyone while it was downloading.
        await _deleteDir(dir);
        throw const ChatAttachmentException(410, 'GONE');
      }
      debugPrint('[DOCUMENT] ${id.substring(0, 8)} cached ($received B)');
      unawaited(prune(keep: id));
      return done;
    } catch (_) {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {
          // Swept on the next start.
        }
      }
      rethrow;
    } finally {
      progress.value = null;
    }
  }

  /// A file name worth showing in a viewer, from the endpoint's
  /// Content-Disposition (the name the document was sent with), made safe for
  /// the file system and always ending in the type's own extension.
  @visibleForTesting
  static String fileNameFor(String? contentDisposition, String ext) {
    var name = '';
    final header = contentDisposition ?? '';
    final star = RegExp(r"filename\*=UTF-8''([^;]+)", caseSensitive: false).firstMatch(header);
    if (star != null) {
      try {
        name = Uri.decodeComponent(star.group(1)!.trim());
      } catch (_) {
        name = '';
      }
    }
    if (name.isEmpty) {
      name = RegExp(r'filename="([^"]*)"', caseSensitive: false).firstMatch(header)?.group(1) ?? '';
    }
    name = name.split(RegExp(r'[\\/]')).last;
    name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '_').trim();
    name = name.replaceFirst(RegExp(r'^\.+'), '');
    if (name.isEmpty) name = 'help24-document';
    if (!name.toLowerCase().endsWith('.$ext')) name = '$name.$ext';
    if (name.length > 120) name = '${name.substring(0, 120 - ext.length - 1)}.$ext';
    return name;
  }

  /// Remove [messageId]'s cached document, if any. Idempotent. Returns how
  /// many files were removed.
  static Future<int> evict(String messageId) async {
    final dir = await _dirFor(messageId);
    if (dir == null) return 0;
    final removed = await _countFiles(dir);
    await _deleteDir(dir);
    if (removed > 0) debugPrint('[DOCUMENT] ${messageId.substring(0, 8)} evicted (files removed: $removed)');
    return removed;
  }

  /// Remove every cached document — at sign-out. Returns how many were removed.
  static Future<int> clearAll() async {
    _inFlight.clear();
    final root = await _root();
    final removed = await _countFiles(root);
    await _deleteDir(root);
    return removed;
  }

  static Future<int> _countFiles(Directory dir) async {
    try {
      if (!await dir.exists()) return 0;
      return await dir.list(recursive: true).where((e) => e is File).length;
    } on FileSystemException {
      return 0;
    }
  }

  /// Keep the cache under [maxCacheBytes], removing the least recently opened
  /// documents first; [keep] is never removed.
  static Future<void> prune({String? keep, int? maxBytes}) async {
    // Runs in the background, so a folder can vanish under it (a deletion
    // for everyone, sign-out). That is never an error worth surfacing.
    try {
      await _prune(keep: keep, limit: maxBytes ?? maxCacheBytes);
    } on FileSystemException catch (e) {
      debugPrint('[DOCUMENT] prune skipped: ${e.osError?.errorCode}');
    }
  }

  static Future<void> _prune({String? keep, required int limit}) async {
    final root = await _root();
    if (!await root.exists()) return;
    final entries = <({Directory dir, int bytes, DateTime used})>[];
    var total = 0;
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      var bytes = 0;
      var used = DateTime.fromMillisecondsSinceEpoch(0);
      try {
        await for (final f in e.list()) {
          if (f is! File) continue;
          final stat = await f.stat();
          bytes += stat.size;
          if (stat.modified.isAfter(used)) used = stat.modified;
        }
      } on FileSystemException {
        continue; // removed while we looked
      }
      total += bytes;
      entries.add((dir: e, bytes: bytes, used: used));
    }
    if (total <= limit) return;
    entries.sort((a, b) => a.used.compareTo(b.used));
    for (final e in entries) {
      if (total <= limit) break;
      if (keep != null && _nameOf(e.dir.path) == keep) continue;
      await _deleteDir(e.dir);
      total -= e.bytes;
    }
  }

  /// Delete `.part-*` leftovers of downloads a killed process never finished.
  static Future<void> _sweepOnce() async {
    if (_swept) return;
    _swept = true;
    try {
      final root = await _root();
      if (!await root.exists()) return;
      await for (final e in root.list(recursive: true)) {
        if (e is File && _isTemp(e.path) && !_inFlightOwns(e.path)) await e.delete();
      }
    } catch (e) {
      debugPrint('[DOCUMENT] sweep failed: ${e.runtimeType}');
    }
  }

  static bool _inFlightOwns(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.length >= 2 && _inFlight.containsKey(parts[parts.length - 2]);
  }

  static String _nameOf(String path) => path.split(RegExp(r'[\\/]')).last;

  @visibleForTesting
  static void resetForTest() {
    _inFlight.clear();
    _progress.clear();
    _swept = false;
  }

  static bool _isTemp(String path) => _nameOf(path).startsWith('.part-');

  static String _extOf(String path) {
    final name = _nameOf(path);
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// Mark a document as just used, for least-recently-used pruning.
  static void _touch(File file) {
    unawaited(file.setLastModified(DateTime.now()).catchError((_) {}));
  }

  static Future<void> _deleteDir(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('[DOCUMENT] could not delete a cached document: ${e.runtimeType}');
    }
  }

  static bool _isConnectivity(Object e) =>
      e is SocketException || e is TimeoutException || e is http.ClientException || e is HandshakeException;

  static Future<bool> _openWithAndroid(String path, String mimeType) async {
    if (!Platform.isAndroid) return false;
    final opened = await _channel.invokeMethod<bool>('openFile', {'path': path, 'mimeType': mimeType});
    return opened ?? false;
  }
}
