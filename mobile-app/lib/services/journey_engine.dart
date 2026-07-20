import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
// widgets.dart is imported only for WidgetsBindingObserver / AppLifecycleState
// (the resume hook). No UI is built in this file.
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_service_supabase.dart';
import 'location_service.dart';
import 'route_service.dart';

// =============================================================================
// Help24 Journey Engine — the single owner of an active journey
// =============================================================================
//
// Phase 2 foundation. Every future journey capability (ETA, routes, dispatch,
// emergency response) builds on this file, so the contract is strict:
//
//   • ONE active journey per device, owned HERE — never by a screen. Screens
//     render snapshots and forward user intent; they hold no timers, no
//     subscriptions, no journey booleans.
//   • The journey is always in EXACTLY ONE state, and only the transitions in
//     [_legalTransitions] are possible. Illegal transitions assert in debug
//     and are refused (logged) in release — they can never corrupt state.
//   • The wire format is unchanged Phase 1 rows (content / live_until /
//     latitude / longitude on chat_messages). Watching devices derive their
//     presentation from the row; the engine exists on the traveller's device
//     only. No schema changes.
//
// ── State diagram ────────────────────────────────────────────────────────────
//
//   idle ──► preparing ──► permissionRequired ──► idle          (user declined)
//              │                   │
//              │                   └─────────► preparing        (granted, retry)
//              ▼
//           starting ──► failed ──► idle                        (insert failed)
//              │
//              ▼
//         travelling ◄────────────► nearby        (geometry, hysteresis)
//              │  ▲                    │
//              │  │ beat ok            │
//              ▼  │                    ▼
//         interrupted ──► reconnecting ─┐         (stream/beat failures)
//              ▲              │         │ success → travelling/nearby
//              └──────────────┘         │
//              │ retry failed           │
//              ▼                        ▼
//   any live state ──► arrived ──► completed ──► idle   (manual or auto-dwell)
//   any live state ──► stopped ──► idle                 (manual stop / cap)
//   reconnecting  ──► failed  ──► idle                  (unrecoverable: GPS
//                                                        permission revoked)
//
// "any live state" = travelling | nearby | interrupted | reconnecting.
//
// ── Arrival detection (auto) ─────────────────────────────────────────────────
// Requires a destination. A GOOD fix (accuracy ≤ 75 m) within 100 m starts a
// 60 s dwell. Two CONSECUTIVE fixes beyond 120 m (hysteresis) — or resumed
// movement — cancel the dwell; a single drift spike does not. Manual
// "I've arrived" is always available and always wins.
//
// ── Battery / write policy ───────────────────────────────────────────────────
// Positions arrive from ONE platform stream (no polling). A beat is written
// when the traveller has moved ≥ 8 m since the last written beat, or 30 s have
// passed (keepalive so the watcher's freshness indicator stays honest while
// parked — 1 write/30 s instead of 1/8 s when stationary).
// =============================================================================

/// UI-toolkit-free coordinate pair (the engine must not depend on maps SDKs).
@immutable
class GeoPoint {
  final double latitude;
  final double longitude;
  const GeoPoint(this.latitude, this.longitude);

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.latitude == latitude && other.longitude == longitude;
  @override
  int get hashCode => Object.hash(latitude, longitude);
}

/// The explicit journey lifecycle. A journey is in exactly one of these.
enum JourneyState {
  idle,
  preparing,
  permissionRequired,
  starting,
  travelling,
  nearby,
  arrived,
  completed,
  stopped,
  interrupted,
  reconnecting,
  failed,
}

/// Why a journey left the live states. Carried on the snapshot for UI copy.
enum JourneyEndReason { manualStop, manualArrival, autoArrival, safetyCap, failure }

/// One-shot things the UI may want to react to (dialogs, toasts). Rendering
/// state, by contrast, always comes from [JourneyEngine.snapshot].
enum JourneyEvent { autoArrived, manualArrived, capExpired, failedPermanently }

/// Immutable view of the engine for the UI. Snapshots with identical fields
/// compare equal, so ValueListenableBuilder subtrees skip no-op rebuilds.
@immutable
class JourneySnapshot {
  final JourneyState state;
  final String? messageId;
  final String? chatId;
  final GeoPoint? destination;
  final GeoPoint? lastFix;
  /// Straight-line metres to destination at the last good fix (null without
  /// a destination or before the first fix).
  final double? distanceToDestinationM;
  final DateTime? startedAt;
  final DateTime? liveUntil;
  final JourneyEndReason? endReason;
  /// Latest computed route (Phase 3). Null when routing is unavailable — the
  /// journey is fully functional without it.
  final JourneyRoute? route;
  /// Smoothed ground speed in m/s (null until enough movement is seen).
  final double? speedMps;

  const JourneySnapshot._({
    required this.state,
    this.messageId,
    this.chatId,
    this.destination,
    this.lastFix,
    this.distanceToDestinationM,
    this.startedAt,
    this.liveUntil,
    this.endReason,
    this.route,
    this.speedMps,
  });

  static const JourneySnapshot idle = JourneySnapshot._(state: JourneyState.idle);

  bool get isLive =>
      state == JourneyState.travelling ||
      state == JourneyState.nearby ||
      state == JourneyState.interrupted ||
      state == JourneyState.reconnecting;

  /// True when this engine owns the given chat_messages row.
  bool owns(String id) => messageId != null && messageId == id;

  JourneySnapshot _with({
    JourneyState? state,
    String? messageId,
    String? chatId,
    GeoPoint? destination,
    GeoPoint? lastFix,
    double? distanceToDestinationM,
    DateTime? startedAt,
    DateTime? liveUntil,
    JourneyEndReason? endReason,
    JourneyRoute? route,
    double? speedMps,
  }) {
    return JourneySnapshot._(
      state: state ?? this.state,
      messageId: messageId ?? this.messageId,
      chatId: chatId ?? this.chatId,
      destination: destination ?? this.destination,
      lastFix: lastFix ?? this.lastFix,
      distanceToDestinationM: distanceToDestinationM ?? this.distanceToDestinationM,
      startedAt: startedAt ?? this.startedAt,
      liveUntil: liveUntil ?? this.liveUntil,
      endReason: endReason ?? this.endReason,
      route: route ?? this.route,
      speedMps: speedMps ?? this.speedMps,
    );
  }

  /// Remaining metres, preferring the real route over straight-line distance.
  double? get remainingMeters =>
      (route != null && !route!.isStale)
          ? route!.distanceMeters.toDouble()
          : distanceToDestinationM;

  /// Live ETA in seconds, or null when there is no usable route.
  int? get etaSeconds =>
      (route != null && !route!.isStale) ? route!.liveDurationSeconds : null;

  @override
  bool operator ==(Object other) =>
      other is JourneySnapshot &&
      other.state == state &&
      other.messageId == messageId &&
      other.chatId == chatId &&
      other.destination == destination &&
      other.lastFix == lastFix &&
      other.distanceToDestinationM == distanceToDestinationM &&
      other.startedAt == startedAt &&
      other.liveUntil == liveUntil &&
      other.endReason == endReason &&
      identical(other.route, route) &&
      other.speedMps == speedMps;

  @override
  int get hashCode => Object.hash(state, messageId, chatId, destination, lastFix,
      distanceToDestinationM, startedAt, liveUntil, endReason, route, speedMps);
}

/// Result of [JourneyEngine.start] so the confirm screen can render the right
/// scenario without inspecting engine internals.
enum JourneyStartResult { started, permissionRequired, serviceDisabled, failed }

class JourneyEngine with WidgetsBindingObserver {
  JourneyEngine._() {
    WidgetsBinding.instance.addObserver(this);
  }
  static final JourneyEngine instance = JourneyEngine._();

  /// App returned to the foreground. Android can silently tear a position
  /// stream down while backgrounded (Doze, background-location limits) without
  /// delivering an error, which would leave a journey "live" but frozen. On
  /// resume, verify the pipeline is genuinely alive and heal it if not — a
  /// lifecycle edge, not a poll.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!snapshot.isLive) return;
    final since = _lastBeatAt;
    final stale = since == null ||
        DateTime.now().difference(since) > beatKeepalive * 2;
    if (!stale) return;
    debugPrint('JourneyEngine: resumed with a stale pipeline — restarting stream');
    _reconnectTimer?.cancel();
    if (snapshot.state == JourneyState.travelling ||
        snapshot.state == JourneyState.nearby) {
      _transition(JourneyState.interrupted);
    }
    _openPositionPipelineKeepingBackoff(_generation);
  }

  // ── Tunables (single source of truth for Phase 2 behaviour) ──
  static const Duration safetyCap = Duration(hours: 2);
  static const Duration beatKeepalive = Duration(seconds: 30);
  static const double beatMinMoveM = 8;
  static const double arrivalRadiusM = 100;
  static const double arrivalExitRadiusM = 120; // hysteresis
  static const Duration arrivalDwell = Duration(seconds: 60);
  /// Used when the corroborating signals disagree with the radius (route says
  /// there is real distance left, or the traveller is still moving). Longer,
  /// never disabled — auto-arrival degrades to cautious, not absent.
  static const Duration arrivalDwellUnconfident = Duration(seconds: 120);
  /// Route distance beyond which "within 100 m" is not believed on its own
  /// (the classic across-the-river / wrong-side-of-the-highway case).
  static const double routeArrivalMaxM = 250;
  /// ~7.2 km/h — above this the traveller is passing through, not arriving.
  static const double movingSpeedMps = 2.0;
  static const double nearbyRadiusM = 300;
  static const double nearbyExitRadiusM = 360; // hysteresis
  static const double goodAccuracyM = 75;
  static const int beatFailStreakForInterrupted = 3;
  static const String _prefsKey = 'journey_engine.active.v1';

  final ValueNotifier<JourneySnapshot> _snapshot = ValueNotifier(JourneySnapshot.idle);
  ValueListenable<JourneySnapshot> get listenable => _snapshot;
  JourneySnapshot get snapshot => _snapshot.value;

  final StreamController<JourneyEvent> _events = StreamController.broadcast();
  Stream<JourneyEvent> get events => _events.stream;

  StreamSubscription<Position>? _positions;
  Timer? _capTimer;
  Timer? _dwellTimer;
  Timer? _reconnectTimer;
  DateTime? _lastBeatAt;
  GeoPoint? _lastBeatPoint;
  GeoPoint? _lastRouteFetchPoint;
  bool _routeFetchInFlight = false;
  DateTime? _lastRouteFailureAt;
  static const Duration _routeFailureBackoffMin = Duration(seconds: 30);
  static const Duration _routeFailureBackoffMax = Duration(minutes: 5);
  Duration _routeFailureBackoff = _routeFailureBackoffMin;
  int _beatFailStreak = 0;
  int _dwellExitStrikes = 0;
  bool _dwellStartedConfident = false;
  int _reconnectAttempt = 0;
  bool _foregroundServiceWanted = false;
  /// Generation guard: every start/adopt/end bumps this; async callbacks from
  /// a previous journey compare it and no-op instead of touching the new one.
  int _generation = 0;

  // ── Legal transitions ──
  static const Map<JourneyState, Set<JourneyState>> _legalTransitions = {
    JourneyState.idle: {JourneyState.preparing, JourneyState.travelling},
    // idle→travelling is the ADOPT path (row already exists: reopen/restart).
    JourneyState.preparing: {
      JourneyState.permissionRequired,
      JourneyState.starting,
      JourneyState.idle,
      JourneyState.failed,
    },
    JourneyState.permissionRequired: {JourneyState.preparing, JourneyState.idle},
    JourneyState.starting: {JourneyState.travelling, JourneyState.failed},
    JourneyState.travelling: {
      JourneyState.nearby,
      JourneyState.interrupted,
      JourneyState.arrived,
      JourneyState.stopped,
    },
    JourneyState.nearby: {
      JourneyState.travelling,
      JourneyState.interrupted,
      JourneyState.arrived,
      JourneyState.stopped,
    },
    JourneyState.interrupted: {
      JourneyState.reconnecting,
      JourneyState.travelling,
      JourneyState.nearby,
      JourneyState.arrived,
      JourneyState.stopped,
    },
    JourneyState.reconnecting: {
      JourneyState.travelling,
      JourneyState.nearby,
      JourneyState.interrupted,
      JourneyState.arrived,
      JourneyState.stopped,
      JourneyState.failed,
    },
    JourneyState.arrived: {JourneyState.completed},
    JourneyState.completed: {JourneyState.idle},
    JourneyState.stopped: {JourneyState.idle},
    JourneyState.failed: {JourneyState.idle},
  };

  void _transition(JourneyState to) {
    final from = _snapshot.value.state;
    if (from == to) return;
    final legal = _legalTransitions[from]?.contains(to) ?? false;
    assert(legal, 'JourneyEngine: illegal transition $from → $to');
    if (!legal) {
      debugPrint('JourneyEngine: REFUSED illegal transition $from → $to');
      return;
    }
    debugPrint('JourneyEngine: $from → $to');
    _snapshot.value = _snapshot.value._with(state: to);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Public API
  // ───────────────────────────────────────────────────────────────────────────

  /// Starts a new journey in [chatId]. Inserts the live row, then owns it.
  /// Any previously active journey is stopped first — one journey per device,
  /// never duplicates.
  Future<JourneyStartResult> start({
    required String chatId,
    required String senderId,
    GeoPoint? destination,
    bool foregroundService = false,
  }) async {
    if (snapshot.isLive) {
      await stop(reason: JourneyEndReason.manualStop);
    }
    final gen = ++_generation;
    _snapshot.value = JourneySnapshot.idle._with(chatId: chatId, destination: destination);
    _transition(JourneyState.preparing);

    // Preflight — the user must never discover mid-drive that nothing shared.
    if (!await Geolocator.isLocationServiceEnabled()) {
      _transition(JourneyState.failed);
      await _release(persistClear: false);
      return JourneyStartResult.serviceDisabled;
    }
    if (!await LocationService.hasPermission()) {
      final granted = await LocationService.requestPermission();
      if (gen != _generation) return JourneyStartResult.failed;
      if (!granted) {
        _transition(JourneyState.permissionRequired);
        return JourneyStartResult.permissionRequired;
      }
      _transition(JourneyState.permissionRequired);
      _transition(JourneyState.preparing);
    }

    final position = await LocationService.getCurrentPosition(requestIfNeeded: false);
    if (gen != _generation) return JourneyStartResult.failed;
    if (position == null) {
      _transition(JourneyState.failed);
      await _release(persistClear: false);
      return JourneyStartResult.serviceDisabled;
    }

    _transition(JourneyState.starting);
    try {
      final message = await ChatServiceSupabase.sendLiveLocation(
        chatId: chatId,
        senderId: senderId,
        latitude: position.latitude,
        longitude: position.longitude,
        durationMinutes: safetyCap.inMinutes,
      );
      if (gen != _generation) return JourneyStartResult.failed;
      final now = DateTime.now();
      _snapshot.value = _snapshot.value._with(
        messageId: message.id,
        startedAt: now,
        liveUntil: message.liveUntil ?? now.add(safetyCap),
        lastFix: GeoPoint(position.latitude, position.longitude),
        distanceToDestinationM: _distanceTo(destination, position),
      );
      _transition(JourneyState.travelling);
      _foregroundServiceWanted = foregroundService;
      _armCap(_snapshot.value.liveUntil!);
      _openPositionPipeline(gen);
      await _persist();
      _maybeEnterNearby(position);
      return JourneyStartResult.started;
    } catch (e) {
      debugPrint('JourneyEngine start: $e');
      if (gen == _generation) {
        _transition(JourneyState.failed);
        await _release(persistClear: false);
      }
      return JourneyStartResult.failed;
    }
  }

  /// Adopts an already-live row (chat reopened, app restarted). Idempotent:
  /// adopting the row the engine already owns is a no-op.
  Future<void> adopt({
    required String messageId,
    required String chatId,
    required DateTime liveUntil,
    GeoPoint? destination,
    bool foregroundService = false,
  }) async {
    if (snapshot.owns(messageId)) return;
    // A start() is in flight: the realtime echo of its own INSERT arrives
    // before sendLiveLocation returns, and adopting here would steal the
    // generation out from under it (observed on device: start() reported a
    // false failure while the adopted pipeline ran fine). The in-flight start
    // owns its row; the echo has nothing to add.
    if (snapshot.state == JourneyState.preparing ||
        snapshot.state == JourneyState.permissionRequired ||
        snapshot.state == JourneyState.starting) {
      return;
    }
    if (snapshot.isLive) {
      // A different journey is active on this device; the newest row wins and
      // the old one is closed so watchers never see two live streams.
      await stop(reason: JourneyEndReason.manualStop);
    }
    if (!liveUntil.isAfter(DateTime.now())) return;
    if (!await LocationService.hasPermission() ||
        !await Geolocator.isLocationServiceEnabled()) {
      // Cannot actually share: close the row instead of leaving a zombie
      // "live" journey that never updates again.
      try {
        await ChatServiceSupabase.stopLiveLocation(messageId);
      } catch (_) {}
      await _clearPersisted();
      return;
    }
    final gen = ++_generation;
    _snapshot.value = JourneySnapshot.idle._with(
      messageId: messageId,
      chatId: chatId,
      destination: destination,
      liveUntil: liveUntil,
      startedAt: DateTime.now(), // presentation uses the row timestamp; this is engine-internal
    );
    _transition(JourneyState.travelling);
    _foregroundServiceWanted = foregroundService;
    _armCap(liveUntil);
    _openPositionPipeline(gen);
    await _persist();
    debugPrint('JourneyEngine: adopted journey $messageId (remaining: '
        '${liveUntil.difference(DateTime.now()).inMinutes} min)');
  }

  /// Called once at app launch: if a journey was live when the process died,
  /// resume it silently so "app restart" never kills an active journey.
  Future<void> resumePersisted() async {
    if (snapshot.state != JourneyState.idle) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final liveUntil = DateTime.tryParse(map['liveUntil'] as String? ?? '');
      final messageId = map['messageId'] as String?;
      final chatId = map['chatId'] as String?;
      if (messageId == null || chatId == null || liveUntil == null) {
        await _clearPersisted();
        return;
      }
      if (!liveUntil.isAfter(DateTime.now())) {
        await _clearPersisted();
        return;
      }
      final destLat = map['destLat'] as num?;
      final destLng = map['destLng'] as num?;
      await adopt(
        messageId: messageId,
        chatId: chatId,
        liveUntil: liveUntil,
        destination: (destLat != null && destLng != null)
            ? GeoPoint(destLat.toDouble(), destLng.toDouble())
            : null,
        foregroundService: map['fgs'] == true,
      );
    } catch (e) {
      debugPrint('JourneyEngine resumePersisted: $e');
      await _clearPersisted();
    }
  }

  /// Manual "I've arrived". Always available from any live state.
  Future<bool> arrive({bool auto = false}) async {
    if (!snapshot.isLive) return false;
    final messageId = snapshot.messageId;
    if (messageId == null) return false;
    _stopPipeline();
    try {
      await ChatServiceSupabase.markJourneyArrived(messageId);
    } catch (_) {
      // Offline arrival: at minimum close the live window so the journey
      // cannot run to the cap; the arrival state is lost, honesty over polish.
      try {
        await ChatServiceSupabase.stopLiveLocation(messageId);
      } catch (_) {}
      _snapshot.value = _snapshot.value._with(endReason: JourneyEndReason.failure);
      _transition(JourneyState.stopped);
      await _release();
      return false;
    }
    _snapshot.value = _snapshot.value._with(
      endReason: auto ? JourneyEndReason.autoArrival : JourneyEndReason.manualArrival,
    );
    _transition(JourneyState.arrived);
    _events.add(auto ? JourneyEvent.autoArrived : JourneyEvent.manualArrived);
    _transition(JourneyState.completed);
    await _release();
    return true;
  }

  /// Manual stop, safety-cap expiry, or teardown on failure.
  Future<void> stop({JourneyEndReason reason = JourneyEndReason.manualStop}) async {
    if (!snapshot.isLive) return;
    final messageId = snapshot.messageId;
    _stopPipeline();
    if (messageId != null) {
      try {
        await ChatServiceSupabase.stopLiveLocation(messageId);
      } catch (_) {}
    }
    _snapshot.value = _snapshot.value._with(endReason: reason);
    _transition(JourneyState.stopped);
    if (reason == JourneyEndReason.safetyCap) _events.add(JourneyEvent.capExpired);
    await _release();
  }

  /// The confirm screen retries after the user grants permission in settings.
  void acknowledgeIdle() {
    final s = snapshot.state;
    if (s == JourneyState.permissionRequired ||
        s == JourneyState.failed ||
        s == JourneyState.completed ||
        s == JourneyState.stopped) {
      _transition(JourneyState.idle);
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Position pipeline
  // ───────────────────────────────────────────────────────────────────────────

  void _openPositionPipeline(int gen) {
    _positions?.cancel();
    _lastBeatAt = null;
    _lastBeatPoint = null;
    _beatFailStreak = 0;
    _reconnectAttempt = 0;
    _positions = LocationService
        .journeyPositionStream(foregroundService: _foregroundServiceWanted)
        .listen(
      (pos) => _onFix(gen, pos),
      onError: (Object e) {
        if (gen != _generation) return;
        debugPrint('JourneyEngine position stream error: $e');
        _onTransportTrouble(gen, streamDied: true);
      },
    );
  }

  Future<void> _onFix(int gen, Position pos) async {
    if (gen != _generation || !snapshot.isLive) return;
    final point = GeoPoint(pos.latitude, pos.longitude);
    final distance = _distanceTo(snapshot.destination, pos);
    _snapshot.value = _snapshot.value._with(
      lastFix: point,
      distanceToDestinationM: distance,
      speedMps: _smoothedSpeed(pos),
    );

    // Recovering from an interruption purely via a healthy GPS fix + beat.
    _updateGeometry(pos, distance);
    unawaited(_maybeRefreshRoute(gen, pos, distance));
    await _maybeBeat(gen, pos);
  }

  /// Exponentially-smoothed ground speed. Geolocator's per-fix speed is noisy
  /// (and −1 on some devices), and arrival logic that trusts a single sample
  /// mistakes a GPS twitch for driving.
  double? _smoothedSpeed(Position pos) {
    final raw = pos.speed;
    if (!raw.isFinite || raw < 0) return snapshot.speedMps;
    final previous = snapshot.speedMps;
    if (previous == null) return raw;
    return previous * 0.7 + raw * 0.3;
  }

  /// Recompute the route only when it would actually tell us something new
  /// (see [RouteService.shouldRefresh]). Fire-and-forget: an ETA must never
  /// delay a position beat, which is what the person waiting actually needs.
  Future<void> _maybeRefreshRoute(int gen, Position pos, double? straightLine) async {
    final destination = snapshot.destination;
    if (destination == null || _routeFetchInFlight) return;
    // Failure cooldown. Without a route the refresh policy always says "yes",
    // so a persistently failing endpoint (quota exhausted, outage, an old
    // build pointed at a backend without the route module) would be retried on
    // EVERY position fix — several times a minute while driving. Back off
    // instead, doubling to a ceiling. Cleared on the first success.
    final failedAt = _lastRouteFailureAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _routeFailureBackoff) {
      return;
    }
    if (!RouteService.shouldRefresh(
      current: snapshot.route,
      lastFetchLat: _lastRouteFetchPoint?.latitude,
      lastFetchLng: _lastRouteFetchPoint?.longitude,
      nowLat: pos.latitude,
      nowLng: pos.longitude,
      straightLineToDestM: straightLine,
    )) {
      return;
    }
    _routeFetchInFlight = true;
    try {
      final route = await RouteService.compute(
        originLat: pos.latitude,
        originLng: pos.longitude,
        destLat: destination.latitude,
        destLng: destination.longitude,
      );
      if (gen != _generation || !snapshot.isLive) return;
      if (route != null) {
        _lastRouteFetchPoint = GeoPoint(pos.latitude, pos.longitude);
        _lastRouteFailureAt = null;
        _routeFailureBackoff = _routeFailureBackoffMin;
        _snapshot.value = _snapshot.value._with(route: route);
      } else {
        _lastRouteFailureAt = DateTime.now();
        final doubled = _routeFailureBackoff * 2;
        _routeFailureBackoff =
            doubled > _routeFailureBackoffMax ? _routeFailureBackoffMax : doubled;
      }
    } finally {
      _routeFetchInFlight = false;
    }
  }

  void _updateGeometry(Position pos, double? distance) {
    final state = snapshot.state;
    final goodFix = pos.accuracy.isFinite && pos.accuracy <= goodAccuracyM;
    if (!goodFix || distance == null) return;

    // ── Arrival dwell (Phase 3: route- and motion-aware) ──
    //
    // Phase 2 asked one question: "within 100 m?". That is right but blunt —
    // 100 m across a river is not arrival, and a provider stopped at a light
    // 90 m away is not either. The radius still gates entry; these signals
    // decide how long we insist on before calling it:
    //
    //   • route remaining — the honest distance (follows roads, not crow
    //     flight). If routing says there is still real distance to cover, the
    //     straight line is lying to us and we hold off.
    //   • speed — someone genuinely arrived has stopped moving. Still driving
    //     through the radius means passing by, not arriving.
    //
    // Both are advisory: absent routing or speed, behaviour is exactly Phase 2.
    if (distance <= arrivalRadiusM) {
      _dwellExitStrikes = 0;
      final routeRemaining = (snapshot.route != null && !snapshot.route!.isStale)
          ? snapshot.route!.distanceMeters.toDouble()
          : null;
      final routeSaysFar = routeRemaining != null && routeRemaining > routeArrivalMaxM;
      final speed = snapshot.speedMps;
      final stillMoving = speed != null && speed > movingSpeedMps;
      final confident = !routeSaysFar && !stillMoving;
      final dwell = confident ? arrivalDwell : arrivalDwellUnconfident;

      if (_dwellTimer == null && (state == JourneyState.travelling || state == JourneyState.nearby)) {
        debugPrint('JourneyEngine: inside ${arrivalRadiusM.toInt()} m — dwell started '
            '(${dwell.inSeconds}s, confident=$confident'
            '${routeRemaining == null ? '' : ', route ${routeRemaining.round()} m'}'
            '${speed == null ? '' : ', ${speed.toStringAsFixed(1)} m/s'})');
        _dwellStartedConfident = confident;
        _dwellTimer = Timer(dwell, () {
          _dwellTimer = null;
          if (snapshot.isLive) {
            debugPrint('JourneyEngine: dwell complete — auto arrival');
            arrive(auto: true);
          }
        });
      } else if (_dwellTimer != null && confident && !_dwellStartedConfident) {
        // Conditions improved mid-dwell (they parked, or the route caught up):
        // restart on the shorter, confident timer rather than making a
        // genuinely-arrived provider wait out the cautious one.
        debugPrint('JourneyEngine: arrival confidence rose — shortening dwell');
        _dwellTimer!.cancel();
        _dwellStartedConfident = true;
        _dwellTimer = Timer(arrivalDwell, () {
          _dwellTimer = null;
          if (snapshot.isLive) arrive(auto: true);
        });
      }
    } else if (_dwellTimer != null && distance > arrivalExitRadiusM) {
      // Hysteresis + spike tolerance: one wild fix does not cancel the dwell,
      // two consecutive ones (or real movement) do.
      _dwellExitStrikes++;
      if (_dwellExitStrikes >= 2) {
        debugPrint('JourneyEngine: left arrival radius — dwell cancelled');
        _dwellTimer?.cancel();
        _dwellTimer = null;
        _dwellExitStrikes = 0;
      }
    }

    // Nearby / travelling with hysteresis (only from healthy states — an
    // interrupted journey stays interrupted until a beat succeeds).
    if (state == JourneyState.travelling && distance <= nearbyRadiusM) {
      _transition(JourneyState.nearby);
    } else if (state == JourneyState.nearby && distance > nearbyExitRadiusM) {
      _transition(JourneyState.travelling);
    }
  }

  Future<void> _maybeBeat(int gen, Position pos) async {
    final now = DateTime.now();
    final movedEnough = _lastBeatPoint == null ||
        Geolocator.distanceBetween(_lastBeatPoint!.latitude, _lastBeatPoint!.longitude,
                pos.latitude, pos.longitude) >=
            beatMinMoveM;
    final keepaliveDue =
        _lastBeatAt == null || now.difference(_lastBeatAt!) >= beatKeepalive;
    if (!movedEnough && !keepaliveDue) return;

    final messageId = snapshot.messageId;
    if (messageId == null) return;
    final ok = await ChatServiceSupabase.updateMessageLocation(
      messageId: messageId,
      latitude: pos.latitude,
      longitude: pos.longitude,
    );
    if (gen != _generation || !snapshot.isLive) return;
    if (ok) {
      if (kDebugMode) {
        debugPrint('JourneyEngine: beat ok (${snapshot.state.name}'
            '${snapshot.distanceToDestinationM == null ? '' : ', ${snapshot.distanceToDestinationM!.round()} m to destination'})');
      }
      _lastBeatAt = now;
      _lastBeatPoint = GeoPoint(pos.latitude, pos.longitude);
      _beatFailStreak = 0;
      _reconnectAttempt = 0;
      final s = snapshot.state;
      if (s == JourneyState.interrupted || s == JourneyState.reconnecting) {
        // Healthy again — geometry decides travelling vs nearby.
        final d = snapshot.distanceToDestinationM;
        _transition((d != null && d <= nearbyRadiusM)
            ? JourneyState.nearby
            : JourneyState.travelling);
      }
    } else {
      _beatFailStreak++;
      if (_beatFailStreak >= beatFailStreakForInterrupted &&
          (snapshot.state == JourneyState.travelling || snapshot.state == JourneyState.nearby)) {
        _onTransportTrouble(gen, streamDied: false);
      }
    }
  }

  /// Transport problems (network beats failing, or the position stream itself
  /// erroring). The journey NEVER ends here — it degrades to interrupted and
  /// heals invisibly. Only permission revocation is unrecoverable.
  void _onTransportTrouble(int gen, {required bool streamDied}) {
    if (gen != _generation || !snapshot.isLive) return;
    if (snapshot.state == JourneyState.travelling || snapshot.state == JourneyState.nearby) {
      _transition(JourneyState.interrupted);
    }
    if (!streamDied) return; // beats keep flowing with each fix; next success heals

    // The stream died — schedule a restart with capped backoff.
    _positions?.cancel();
    _positions = null;
    final delay = Duration(seconds: [2, 4, 8, 15, 30][_reconnectAttempt.clamp(0, 4)]);
    _reconnectAttempt++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      if (gen != _generation || !snapshot.isLive) return;
      if (snapshot.state == JourneyState.interrupted) {
        _transition(JourneyState.reconnecting);
      }
      final hasPermission = await LocationService.hasPermission();
      if (gen != _generation || !snapshot.isLive) return;
      if (!hasPermission) {
        // Permission revoked mid-journey: unrecoverable. Close the row so the
        // watcher is not left staring at a frozen "live" marker.
        debugPrint('JourneyEngine: permission revoked mid-journey — failing');
        final messageId = snapshot.messageId;
        _stopPipeline();
        if (messageId != null) {
          try {
            await ChatServiceSupabase.stopLiveLocation(messageId);
          } catch (_) {}
        }
        _snapshot.value = _snapshot.value._with(endReason: JourneyEndReason.failure);
        _transition(JourneyState.failed);
        _events.add(JourneyEvent.failedPermanently);
        await _release();
        return;
      }
      _openPositionPipelineKeepingBackoff(gen);
    });
  }

  /// Restart the stream WITHOUT resetting the backoff counter (unlike
  /// [_openPositionPipeline]) so a flapping GPS cannot hot-loop restarts.
  void _openPositionPipelineKeepingBackoff(int gen) {
    _positions?.cancel();
    _positions = LocationService
        .journeyPositionStream(foregroundService: _foregroundServiceWanted)
        .listen(
      (pos) => _onFix(gen, pos),
      onError: (Object e) {
        if (gen != _generation) return;
        debugPrint('JourneyEngine position stream error (retry): $e');
        _onTransportTrouble(gen, streamDied: true);
      },
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Internals
  // ───────────────────────────────────────────────────────────────────────────

  void _armCap(DateTime liveUntil) {
    _capTimer?.cancel();
    final remaining = liveUntil.difference(DateTime.now());
    _capTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      if (snapshot.isLive) stop(reason: JourneyEndReason.safetyCap);
    });
  }

  double? _distanceTo(GeoPoint? destination, Position pos) {
    if (destination == null) return null;
    return Geolocator.distanceBetween(
        pos.latitude, pos.longitude, destination.latitude, destination.longitude);
  }

  void _maybeEnterNearby(Position pos) {
    final d = _distanceTo(snapshot.destination, pos);
    final goodFix = pos.accuracy.isFinite && pos.accuracy <= goodAccuracyM;
    if (d != null && goodFix && d <= nearbyRadiusM && snapshot.state == JourneyState.travelling) {
      _transition(JourneyState.nearby);
    }
  }

  void _stopPipeline() {
    _positions?.cancel();
    _positions = null;
    _capTimer?.cancel();
    _capTimer = null;
    _dwellTimer?.cancel();
    _dwellTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _dwellExitStrikes = 0;
    _dwellStartedConfident = false;
    _beatFailStreak = 0;
    _reconnectAttempt = 0;
    _lastRouteFetchPoint = null;
    _routeFetchInFlight = false;
    _lastRouteFailureAt = null;
    _routeFailureBackoff = _routeFailureBackoffMin;
    _generation++;
  }

  /// Terminal cleanup: clear persistence and return to idle, keeping the
  /// terminal snapshot visible for one frame so listeners can react.
  Future<void> _release({bool persistClear = true}) async {
    if (persistClear) await _clearPersisted();
    _foregroundServiceWanted = false;
    final terminal = snapshot.state;
    if (terminal == JourneyState.completed ||
        terminal == JourneyState.stopped ||
        terminal == JourneyState.failed) {
      _transition(JourneyState.idle);
    }
    // Preserve endReason/messageId etc. only while non-idle; a fresh idle
    // snapshot avoids stale data leaking into the next journey.
    if (snapshot.state == JourneyState.idle) {
      _snapshot.value = JourneySnapshot.idle;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = snapshot;
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'messageId': s.messageId,
          'chatId': s.chatId,
          'liveUntil': s.liveUntil?.toIso8601String(),
          'destLat': s.destination?.latitude,
          'destLng': s.destination?.longitude,
          'fgs': _foregroundServiceWanted,
        }),
      );
    } catch (e) {
      debugPrint('JourneyEngine persist: $e');
    }
  }

  Future<void> _clearPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }
}
