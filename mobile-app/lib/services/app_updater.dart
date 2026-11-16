import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/remote_config.dart';

/// Which store this build is for. Sideloaded builds (the default, and every
/// build today) update themselves; a future Play Store build passes
/// `--dart-define=HELP24_STORE=play` (and `-Phelp24Store=play` to Gradle, which
/// drops the install permission), because Play does not allow an app to
/// install its own updates.
const String kHelp24Store = String.fromEnvironment('HELP24_STORE', defaultValue: 'sideload');

bool get inAppUpdatesBuild => kHelp24Store != 'play';

/// The update the app can download and install itself: the APK, its SHA-256
/// and its size, from `ops.min_version` (apk_url, sha256, size_bytes).
@immutable
class UpdateTarget {
  const UpdateTarget({required this.url, required this.sha256, required this.sizeBytes});

  final String url;

  /// Lowercase hex. Nothing is installed unless the file hashes to this.
  final String sha256;
  final int sizeBytes;

  /// The in-app target, or null when the Update button should open the
  /// download page instead: a Play build, not Android, or the config lacks any
  /// of the three fields.
  static UpdateTarget? fromConfig(MinVersionConfig m, {bool? android, bool? enabled}) {
    if (!(enabled ?? inAppUpdatesBuild)) return null;
    if (!(android ?? (!kIsWeb && Platform.isAndroid))) return null;
    if (!m.hasInAppDownload) return null;
    return UpdateTarget(url: m.apkUrl.trim(), sha256: m.sha256.trim().toLowerCase(), sizeBytes: m.sizeBytes);
  }

  /// File name on disk: the checksum keeps two releases from sharing a file.
  String get fileStem => 'help24-${sha256.substring(0, 12)}';

  @override
  bool operator ==(Object other) => other is UpdateTarget && other.sha256 == sha256 && other.url == url;

  @override
  int get hashCode => Object.hash(url, sha256);
}

/// "85 MB": decimal megabytes, the way Android itself shows sizes.
String formatUpdateSize(int bytes) {
  final mb = bytes / 1000000;
  return mb >= 10 ? '${mb.round()} MB' : '${mb.toStringAsFixed(1)} MB';
}

/// Android's half of the updater (MainActivity, channel com.help24.help24/updater).
abstract class UpdateInstaller {
  /// Whether Help24 may open the install prompt ("Install unknown apps").
  Future<bool> canInstall();

  /// Opens that setting for Help24. True when the screen opened.
  Future<bool> openInstallSettings();

  /// Opens Android's install prompt for the APK at [path]. True when it opened.
  Future<bool> install(String path);
}

class ChannelUpdateInstaller implements UpdateInstaller {
  const ChannelUpdateInstaller();

  static const MethodChannel _channel = MethodChannel('com.help24.help24/updater');

  @override
  Future<bool> canInstall() async => await _channel.invokeMethod<bool>('canInstall') ?? false;

  @override
  Future<bool> openInstallSettings() async =>
      await _channel.invokeMethod<bool>('openInstallSettings') ?? false;

  @override
  Future<bool> install(String path) async =>
      await _channel.invokeMethod<bool>('install', {'path': path}) ?? false;
}

enum UpdatePhase {
  /// Nothing running. A cancelled download keeps its partial file and resumes.
  idle,
  downloading,
  verifying,

  /// Verified, but Android has not let Help24 install apps yet.
  needsPermission,

  /// Verified, and the install prompt was opened. If the member backed out of
  /// it, the panel offers it again.
  readyToInstall,
  failed,
}

enum UpdateFailure { network, checksum, installer, storage }

/// Downloads, verifies and installs an update of the sideloaded app.
///
/// THE RULE: nothing is installed unless its SHA-256 matches the value in
/// remote config. A file that does not match is deleted, never offered.
///
/// The file goes to the app's cache (`<cache>/updates`), so no storage
/// permission is needed, and Android may clear it. A cancelled or broken
/// download keeps its partial file and resumes with an HTTP Range request
/// where the server allows it. Files of other releases are deleted.
class AppUpdater extends ChangeNotifier with WidgetsBindingObserver {
  AppUpdater({
    http.Client? client,
    UpdateInstaller? installer,
    Future<Directory> Function()? cacheDir,
    Future<bool> Function()? onWifi,
  })  : _client = client,
        _installer = installer ?? const ChannelUpdateInstaller(),
        _cacheDir = cacheDir ?? getTemporaryDirectory,
        _onWifi = onWifi ?? _wifiNow;

  static final AppUpdater instance = AppUpdater();

  final http.Client? _client;
  final UpdateInstaller _installer;
  final Future<Directory> Function() _cacheDir;
  final Future<bool> Function() _onWifi;

  UpdateTarget? _target;
  UpdatePhase _phase = UpdatePhase.idle;
  UpdateFailure? _failure;
  int _received = 0;
  StreamSubscription<List<int>>? _subscription;
  IOSink? _sink;
  Completer<void>? _download;
  bool _observing = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  UpdateTarget? get target => _target;
  UpdatePhase get phase => _phase;
  UpdateFailure? get failure => _failure;

  /// Bytes on disk so far for the current target.
  int get received => _received;

  /// 0 to 1 while downloading.
  double get progress {
    final total = _target?.sizeBytes ?? 0;
    return total <= 0 ? 0 : (_received / total).clamp(0, 1).toDouble();
  }

  bool get busy => _phase == UpdatePhase.downloading || _phase == UpdatePhase.verifying;

  /// Whether the phone is on Wi-Fi (or Ethernet). The panel mentions mobile
  /// data before a download when it is not.
  Future<bool> isOnWifi() => _onWifi();

  static Future<bool> _wifiNow() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.contains(ConnectivityResult.wifi) || results.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return true; // unknown: do not warn
    }
  }

  // ── Files ────────────────────────────────────────────────────────────────

  Future<Directory> _dir() async {
    final dir = Directory('${(await _cacheDir()).path}${Platform.pathSeparator}updates');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _partFile(UpdateTarget t) async => File('${(await _dir()).path}${Platform.pathSeparator}${t.fileStem}.apk.part');
  Future<File> _apkFile(UpdateTarget t) async => File('${(await _dir()).path}${Platform.pathSeparator}${t.fileStem}.apk');

  /// Deletes downloaded updates other than [keep]'s; with no [keep], all of them.
  /// Called at start-up (an installed update leaves its file behind) and before
  /// a new download.
  Future<void> cleanup({UpdateTarget? keep}) async {
    try {
      final dir = await _dir();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (keep != null && name.startsWith(keep.fileStem)) continue;
        await entity.delete();
      }
    } catch (e) {
      debugPrint('[UPDATE] cleanup failed: $e');
    }
  }

  // ── Flow ─────────────────────────────────────────────────────────────────

  /// Downloads [t] (resuming a partial file), verifies it, then installs it or
  /// asks for the install permission. Safe to call again: a running download
  /// is left alone, a finished one is not fetched again.
  Future<void> start(UpdateTarget t) async {
    if (busy && _target == t) return;
    if (_target != null && _target != t) await cancel();
    _target = t;
    _failure = null;
    _watchLifecycle();
    await cleanup(keep: t);

    final apk = await _apkFile(t);
    if (await apk.exists()) {
      await _verifyAndInstall(t);
      return;
    }
    await _downloadInto(t);
  }

  Future<void> _downloadInto(UpdateTarget t) async {
    final part = await _partFile(t);
    var offset = await part.exists() ? await part.length() : 0;
    if (offset > t.sizeBytes) {
      await part.delete();
      offset = 0;
    }
    _received = offset;
    _set(UpdatePhase.downloading);

    if (offset < t.sizeBytes) {
      final client = _client ?? http.Client();
      try {
        final request = http.Request('GET', Uri.parse(t.url));
        if (offset > 0) request.headers['Range'] = 'bytes=$offset-';
        final response = await client.send(request);
        final resumed = response.statusCode == 206;
        if (response.statusCode != 200 && !resumed) {
          debugPrint('[UPDATE] download refused: HTTP ${response.statusCode}');
          return _fail(UpdateFailure.network);
        }
        if (!resumed) _received = 0;
        _sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
        final done = _download = Completer<void>();
        _subscription = response.stream.listen(
          (chunk) {
            _sink?.add(chunk);
            _received += chunk.length;
            _notifyThrottled();
          },
          onError: (Object e) {
            debugPrint('[UPDATE] download broke at $_received bytes: $e');
            if (!done.isCompleted) done.completeError(e);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        await done.future;
      } catch (e) {
        await _closeSink();
        if (_phase != UpdatePhase.downloading) return; // cancelled
        return _fail(UpdateFailure.network);
      } finally {
        _subscription = null;
        _download = null;
        if (_client == null) client.close();
      }
      await _closeSink();
      if (_phase != UpdatePhase.downloading) return; // cancelled
    }

    try {
      await part.rename((await _apkFile(t)).path);
    } catch (e) {
      debugPrint('[UPDATE] could not finish the file: $e');
      return _fail(UpdateFailure.storage);
    }
    await _verifyAndInstall(t);
  }

  Future<void> _verifyAndInstall(UpdateTarget t) async {
    final apk = await _apkFile(t);
    _set(UpdatePhase.verifying);
    String digest;
    try {
      final path = apk.path;
      digest = await Isolate.run(() => _sha256Of(path));
    } catch (e) {
      debugPrint('[UPDATE] could not read the download: $e');
      await _deleteQuietly(apk);
      return _fail(UpdateFailure.storage);
    }
    if (digest != t.sha256) {
      debugPrint('[UPDATE] checksum mismatch: got ${digest.substring(0, 12)}, expected ${t.sha256.substring(0, 12)}');
      await _deleteQuietly(apk);
      _received = 0;
      return _fail(UpdateFailure.checksum);
    }
    await _installVerified(t);
  }

  Future<void> _installVerified(UpdateTarget t) async {
    final apk = await _apkFile(t);
    if (!await apk.exists()) return _fail(UpdateFailure.storage);
    bool allowed;
    try {
      allowed = await _installer.canInstall();
    } catch (_) {
      allowed = false;
    }
    if (!allowed) return _set(UpdatePhase.needsPermission);
    bool opened;
    try {
      opened = await _installer.install(apk.path);
    } catch (e) {
      debugPrint('[UPDATE] install prompt failed: $e');
      opened = false;
    }
    if (!opened) return _fail(UpdateFailure.installer);
    _set(UpdatePhase.readyToInstall);
  }

  /// "Open settings": Android's "Install unknown apps" page for Help24. The
  /// flow continues by itself when the member comes back ([didChangeAppLifecycleState]).
  Future<void> openInstallSettings() async {
    try {
      await _installer.openInstallSettings();
    } catch (e) {
      debugPrint('[UPDATE] settings did not open: $e');
    }
  }

  /// "Install update" again, after the member backed out of the prompt.
  Future<void> installAgain() async {
    final t = _target;
    if (t == null) return;
    await _installVerified(t);
  }

  /// Back from Settings (or from the install prompt): carry on if allowed now.
  Future<void> resumeAfterSettings() async {
    final t = _target;
    if (t == null || _phase != UpdatePhase.needsPermission) return;
    await _installVerified(t);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(resumeAfterSettings());
  }

  /// Stops a download. The partial file stays, so the next start resumes it.
  Future<void> cancel() async {
    if (_phase != UpdatePhase.downloading) return;
    _phase = UpdatePhase.idle;
    final sub = _subscription;
    _subscription = null;
    await sub?.cancel();
    final pending = _download;
    if (pending != null && !pending.isCompleted) pending.complete();
    await _closeSink();
    notifyListeners();
  }

  /// "Try again" after a failure: resumes or restarts the download.
  Future<void> retry() async {
    final t = _target;
    if (t == null) return;
    _failure = null;
    await start(t);
  }

  // ── Internals ────────────────────────────────────────────────────────────

  void _watchLifecycle() {
    if (_observing) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    } catch (_) {
      // No binding (pure unit tests): resumeAfterSettings is called directly.
    }
  }

  Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;
    try {
      await sink?.flush();
      await sink?.close();
    } catch (_) {}
  }

  Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  void _fail(UpdateFailure failure) {
    _failure = failure;
    _set(UpdatePhase.failed);
  }

  void _set(UpdatePhase phase) {
    _phase = phase;
    notifyListeners();
  }

  void _notifyThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastNotify) < const Duration(milliseconds: 120)) return;
    _lastNotify = now;
    notifyListeners();
  }

  @visibleForTesting
  Future<String> filePathFor(UpdateTarget t) async => (await _apkFile(t)).path;

  @visibleForTesting
  Future<String> partPathFor(UpdateTarget t) async => (await _partFile(t)).path;

  @override
  void dispose() {
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// SHA-256 of a file, streamed (runs in a background isolate).
Future<String> _sha256Of(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}
