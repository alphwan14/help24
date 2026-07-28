import 'dart:async';

import 'package:flutter/foundation.dart';

import '../providers/connectivity_provider.dart' show NetworkHealth;

/// A repeating background refresh that STOPS when the app is offline and
/// resumes with one immediate run when it comes back.
///
/// WHY THIS EXISTS
/// ---------------
/// Nine `Timer.periodic`s across the app fired network requests on a fixed
/// cadence and none of them knew what connectivity was. Losing signal did not
/// slow any of them down:
///
///   * the conversation list refetched every 15s, forever, through an outage;
///   * `watchUser` and the settings watcher refetched every 15s each;
///   * a chat polled typing every 3s and presence every 30s;
///   * presence heartbeats wrote every 60s;
///   * job-status and campaign cards polled every 30s and 5s.
///
/// Every one of those ticks failed. The cost was not only battery and radio
/// wake-ups on the metered connections most Help24 users are on — it was
/// CORRECTNESS. Each failed tick produced an error that some listener then had
/// to interpret, which is how a dead network came to be published as "you have
/// no conversations" (see `conversationEmissionFor`). A poll that knows it
/// cannot succeed should not run: the tick it skips is a tick that cannot be
/// misread.
///
/// THE CONTRACT
///   * offline  → no timer, no ticks, nothing scheduled;
///   * reconnect → exactly ONE immediate tick, then the normal interval resumes;
///   * online   → an ordinary periodic poll.
///
/// Reconnection is read from [NetworkHealth], the same single edge source that
/// `ConnectivityProvider.onReconnect` and every `ReconnectListener` widget read,
/// so a service poller and a screen can never disagree about when the network
/// came back.
///
/// DELIBERATELY NOT USED BY THE PAYMENT POLL
/// `PaymentScreen` counts its ticks as a proxy for wall-clock time, because the
/// M-Pesa STK push on the user's handset expires on Safaricom's clock and not
/// on ours. Pausing that poll would stop the count while the real prompt kept
/// expiring, so the screen would wait past a deadline that had already passed.
/// A poll whose ticks measure elapsed time is a timer, not a refresh, and it
/// stays a plain `Timer.periodic` on purpose.
class AdaptivePoll {
  AdaptivePoll({
    required Duration interval,
    required FutureOr<void> Function() onTick,
    this.debugLabel = 'poll',
    this.tickOnStart = true,
  })  : _interval = interval,
        _onTick = onTick;

  /// Named in debug output so a misbehaving poller is identifiable.
  final String debugLabel;

  /// Whether [start] runs [onTick] immediately (when online) or waits one full
  /// interval. Most refreshes want the immediate run; a heartbeat that another
  /// code path already fired does not.
  final bool tickOnStart;

  final FutureOr<void> Function() _onTick;

  Duration _interval;
  Timer? _timer;
  StreamSubscription<bool>? _status;
  bool _started = false;
  bool _disposed = false;

  /// True while a timer is armed — i.e. online and polling.
  bool get isPolling => _timer != null;

  /// True once [start] has run and [dispose] has not.
  bool get isStarted => _started && !_disposed;

  Duration get interval => _interval;

  /// Change the cadence, re-arming immediately if currently polling.
  ///
  /// The conversation stream uses this: it starts at 15s and stretches to 60s
  /// once Realtime proves it is alive, because the poll is then only a safety
  /// net.
  set interval(Duration value) {
    if (_interval == value) return;
    _interval = value;
    if (_timer != null) _arm();
  }

  /// Begin polling. Idempotent — calling it twice does not double the cadence.
  ///
  /// Subscribes to connectivity FIRST, so a poller started while offline is
  /// already listening for the reconnect that will bring it to life.
  void start() {
    if (_disposed || _started) return;
    _started = true;

    _status ??= NetworkHealth.onStatusChange.listen((offline) {
      if (_disposed || !_started) return;
      if (offline) {
        _disarm();
      } else {
        // Reconnected: ONE immediate catch-up, then the ordinary cadence. The
        // immediate run is the point — waiting a full interval after the network
        // returns is exactly the stale window users read as "the app needs a
        // pull to refresh".
        _fire();
        _arm();
      }
    });

    if (NetworkHealth.isOffline) {
      if (kDebugMode) debugPrint('[$debugLabel] offline — poll parked');
      return;
    }
    if (tickOnStart) _fire();
    _arm();
  }

  /// Stop polling but stay subscribed, so a later reconnect does NOT revive it.
  /// Use [start] again to resume. Prefer [dispose] when the owner is going away.
  void stop() {
    _started = false;
    _disarm();
    _status?.cancel();
    _status = null;
  }

  void dispose() {
    _disposed = true;
    _started = false;
    _disarm();
    _status?.cancel();
    _status = null;
  }

  /// Run the tick now, out of band, without disturbing the schedule.
  /// A no-op while offline — the whole point is not to make doomed calls.
  void refreshNow() {
    if (_disposed || NetworkHealth.isOffline) return;
    _fire();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) {
      // Belt and braces: connectivity may have changed between the timer being
      // armed and this tick firing, and a doomed request is worse than a skip.
      if (NetworkHealth.isOffline) {
        _disarm();
        return;
      }
      _fire();
    });
  }

  void _disarm() {
    _timer?.cancel();
    _timer = null;
  }

  void _fire() {
    try {
      final result = _onTick();
      if (result is Future) {
        // A poll tick is fire-and-forget by nature; an unawaited rejection would
        // otherwise surface as an unhandled async error and crash debug builds.
        result.catchError((Object e) {
          debugPrint('[$debugLabel] tick failed: $e');
        });
      }
    } catch (e) {
      debugPrint('[$debugLabel] tick threw: $e');
    }
  }
}
