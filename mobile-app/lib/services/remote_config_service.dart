import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../models/remote_config.dart';
import 'api_client.dart';

/// Backend-served client configuration: kill switches, maintenance notice,
/// version gates and the operational tunables that used to require a release.
///
/// THE LOADING CONTRACT
/// --------------------
/// Deliberately the same three-stage shape as [ReferenceRegistry], because the
/// same property is being bought — a value the server owns that the app must
/// still have when the server is unreachable:
///
///   compiled defaults  →  device cache  →  server
///   (always there)        (last known)     (authoritative, versioned)
///
/// Every stage only ever UPGRADES what is in memory, and every stage may fail
/// silently. The worst possible outcome is the app behaving exactly like the
/// build that shipped.
///
/// WHAT THIS DOES NOT DO
/// ---------------------
/// It never blocks the launch. [warmUp] reads SharedPreferences and returns;
/// the network refresh is fired separately, after the first frame, so the cold
/// start remains the single transaction it is today (see LaunchSequence). A
/// config plane that could delay the splash would be a worse trade than the
/// releases it saves.
///
/// It never throws. Callers read [config] synchronously and always get a
/// complete document.
///
/// FAIL-OPEN, WITH ONE EXCEPTION
/// -----------------------------
/// Switches default to ENABLED and stay enabled when anything goes wrong: the
/// point of the plane is to disable a broken feature deliberately, never to
/// disable a working one by accident. Maintenance is the exception and defaults
/// to OFF for the mirror-image reason.
class RemoteConfigService extends ChangeNotifier {
  RemoteConfigService._();

  static final RemoteConfigService instance = RemoteConfigService._();

  /// How long a fetched document is trusted before a refresh is attempted.
  /// Expiry never invalidates the config; it only permits a refresh.
  static const Duration ttl = Duration(minutes: 15);

  /// Short. This is a small cached document on the server, and a slow answer is
  /// worth less than the compiled defaults available instantly.
  static const Duration _timeout = Duration(seconds: 8);

  static const String _cacheKey = 'help24_remote_config_v1';
  static const String _cacheAtKey = 'help24_remote_config_at_v1';
  static const String _versionKey = 'help24_remote_config_version_v1';
  static const String _dismissedAnnouncementKey =
      'help24_remote_config_dismissed_announcement_v1';

  RemoteConfig _config = RemoteConfig.defaults;
  String? _version;
  DateTime? _fetchedAt;
  String _appVersion = '';
  String _dismissedAnnouncementId = '';

  /// Snapshot taken at cold start, before any refresh could land.
  ///
  /// The hard version gate reads THIS, not [config]: a blocking screen that
  /// appears mid-session — over a half-finished payment, say — would be a worse
  /// failure than the outdated client it is trying to stop. A hard gate takes
  /// effect at the next cold start, which is soon enough for a control whose
  /// remedy is "go to the Play Store" anyway.
  RemoteConfig _launchConfig = RemoteConfig.defaults;

  Future<void>? _inflight;
  bool _warmedUp = false;

  /// The transport, resolved LAZILY.
  ///
  /// Deliberately a getter rather than an initialised field: touching [api]
  /// during construction would build a real `HttpClient`, and this class is a
  /// singleton constructed the moment anything reads it — including from a test
  /// zone, where creating one throws. Nothing should build a socket just because
  /// a config value was read.
  ///
  /// Overridable ONLY by tests: the cache/ETag/failure behaviour here is the
  /// part that has to keep working during an incident, so it must be
  /// exercisable without a network.
  http.Client? _transportOverride;
  http.Client get _http => _transportOverride ?? api;

  /// The live configuration. Never null, never partial, safe before [warmUp].
  RemoteConfig get config => _config;

  /// The configuration as it stood at cold start.
  RemoteConfig get launchConfig => _launchConfig;

  /// The running app's version ("1.2.3"), or '' before [warmUp] resolves it.
  String get appVersion => _appVersion;

  /// True once anything — cache or server — has been loaded.
  bool get isLoaded => _warmedUp;

  // ── Convenience readers ────────────────────────────────────────────────────
  // Call sites read these rather than reaching into the document, so a gate
  // reads as a sentence and the fail-open default lives in exactly one place.

  bool get paymentsEnabled => _config.killSwitches.payments;
  bool get promotionsEnabled => _config.killSwitches.promotions;
  bool get postingEnabled => _config.killSwitches.posting;
  bool get applicationsEnabled => _config.killSwitches.applications;

  /// Blocking update required — evaluated against the LAUNCH snapshot.
  bool get requiresHardUpdate =>
      isBelowVersion(_appVersion, _launchConfig.minVersion.hard);

  /// Dismissible update banner — evaluated against live config, since a
  /// suggestion appearing mid-session interrupts nothing.
  bool get suggestsUpdate =>
      !requiresHardUpdate && isBelowVersion(_appVersion, _config.minVersion.soft);

  /// The announcement to show, or null when there is none the user has not
  /// already dismissed.
  AnnouncementConfig? get visibleAnnouncement {
    final announcement = _config.announcement;
    if (!announcement.shouldShow) return null;
    if (announcement.id == _dismissedAnnouncementId) return null;
    return announcement;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Load the cached document and the app version. Disk only — no network.
  ///
  /// Safe to call from anywhere as often as you like; concurrent calls share one
  /// future. Never throws.
  Future<void> warmUp() {
    return _inflight ??= _warmUp().whenComplete(() => _inflight = null);
  }

  Future<void> _warmUp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      if (cached != null) {
        final decoded = jsonDecode(cached);
        if (decoded is Map<String, dynamic>) {
          _config = RemoteConfig.fromJson(decoded);
        }
      }
      _version = prefs.getString(_versionKey);
      final at = prefs.getInt(_cacheAtKey);
      _fetchedAt = at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
      _dismissedAnnouncementId =
          prefs.getString(_dismissedAnnouncementKey) ?? '';
    } catch (e) {
      // A corrupt cache is indistinguishable from no cache, and both mean the
      // same thing: use the compiled defaults.
      debugPrint('[CONFIG] cache read failed — using defaults: $e');
      _config = RemoteConfig.defaults;
    }

    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = info.version;
    } catch (e) {
      // Unknown version is never gated — isBelowVersion('') answers false.
      debugPrint('[CONFIG] app version unavailable: $e');
      _appVersion = '';
    }

    _launchConfig = _config;
    _warmedUp = true;
    notifyListeners();
  }

  /// Fetch from the backend if the cached document has gone stale.
  ///
  /// Call after the first frame and on resume. Returns immediately when the
  /// cache is fresh, so a user flipping in and out of the app costs nothing.
  Future<void> refreshIfStale() async {
    final at = _fetchedAt;
    if (at != null && DateTime.now().difference(at) < ttl) return;
    await refresh();
  }

  /// Fetch from the backend unconditionally. Never throws.
  Future<void> refresh() async {
    if (!_warmedUp) await warmUp();
    try {
      final uri = Uri.parse(ApiConfig.clientConfig).replace(queryParameters: {
        // Not acted on by the server today — it is how the access log answers
        // "is anyone still below the soft gate?".
        'platform': defaultTargetPlatform.name,
        if (_appVersion.isNotEmpty) 'app_version': _appVersion,
      });

      final version = _version;
      final response = await _http
          .get(uri, headers: {
            if (version != null && version.isNotEmpty)
              'If-None-Match': '"$version"',
          })
          .timeout(_timeout);

      if (response.statusCode == 304) {
        // Unchanged. Stamp the cache so we do not re-ask for another TTL.
        await _stampFetchedAt();
        return;
      }
      if (response.statusCode != 200) {
        debugPrint('[CONFIG] refresh got HTTP ${response.statusCode} — keeping current config');
        return;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return;
      final configJson = decoded['config'];
      if (configJson is! Map<String, dynamic>) return;

      final next = RemoteConfig.fromJson(configJson);
      final nextVersion = decoded['version'];
      _config = next;
      _version = nextVersion is String ? nextVersion : null;
      await _persist(configJson, _version);
      debugPrint('[CONFIG] applied (version=$_version)');
      notifyListeners();
    } catch (e) {
      // Offline, backend down, an old build with no /config route, a malformed
      // body — all the same answer: keep what we have.
      debugPrint('[CONFIG] refresh failed (keeping current config): $e');
    }
  }

  /// Remember that this announcement has been seen.
  Future<void> dismissAnnouncement(String id) async {
    if (id.isEmpty) return;
    _dismissedAnnouncementId = id;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dismissedAnnouncementKey, id);
    } catch (e) {
      // A dismissal that does not survive a restart is a small annoyance; a
      // crash while dismissing a banner is not.
      debugPrint('[CONFIG] dismissal not persisted: $e');
    }
  }

  Future<void> _persist(Map<String, dynamic> configJson, String? version) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(configJson));
      await prefs.setInt(_cacheAtKey, DateTime.now().millisecondsSinceEpoch);
      if (version != null) await prefs.setString(_versionKey, version);
      _fetchedAt = DateTime.now();
    } catch (e) {
      debugPrint('[CONFIG] cache write failed: $e');
    }
  }

  Future<void> _stampFetchedAt() async {
    _fetchedAt = DateTime.now();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_cacheAtKey, _fetchedAt!.millisecondsSinceEpoch);
    } catch (_) {
      // In-memory stamp is enough to avoid re-asking this session.
    }
  }

  /// Test seam — restores the pristine state a fresh install would have.
  ///
  /// [transport] injects a stand-in HTTP client so the cache, ETag and failure
  /// paths can be exercised without a network; passing null restores the real
  /// authenticated client.
  @visibleForTesting
  void resetForTest({
    RemoteConfig? config,
    String appVersion = '',
    http.Client? transport,
  }) {
    _config = config ?? RemoteConfig.defaults;
    _launchConfig = _config;
    _version = null;
    _fetchedAt = null;
    _appVersion = appVersion;
    _dismissedAnnouncementId = '';
    _warmedUp = false;
    _inflight = null;
    _transportOverride = transport;
  }

  /// Test seam — the version the client would send as `If-None-Match`.
  @visibleForTesting
  String? get cachedVersionForTest => _version;
}
