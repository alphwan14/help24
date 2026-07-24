import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';

/// Whether the app can actually REACH Help24 — not whether a network interface
/// exists.
///
/// THE BUG THIS REPLACES
/// The previous implementation asked connectivity_plus for the interface state
/// and treated anything other than `none` as online. On mobile data that is the
/// wrong question: when a data bundle expires the radio stays up and Android
/// keeps reporting `mobile`, so the app believed it was online, fired requests
/// that never completed, and sat on skeleton loaders forever while perfectly
/// good cached content was already on disk. Users read that as a broken app.
///
/// EVIDENCE, NOT GUESSWORK
/// Reachability is derived from what actually happens to real requests:
///
///   • [reportSuccess] — any successful response proves the internet works.
///     Free: it reuses traffic the app was making anyway.
///   • [reportFailure] — a timeout or socket error is SUSPICION, not proof; one
///     failing endpoint is not a dead internet. Only after
///     [_failuresBeforeProbe] consecutive failures do we spend a probe.
///   • [checkNow] — one small, short-timeout request that settles the question.
///
/// WHEN WE PROBE (never on a timer — polling is what drains batteries)
///   • the network interface changes (SIM inserted, Wi-Fi joined)
///   • the app returns to the foreground
///   • consecutive request failures cross the threshold
///   • the user explicitly retries
/// While offline, retries use capped backoff, so a genuinely dead connection
/// costs a handful of tiny requests per hour rather than a constant drip.
///
/// The probe targets our own /health endpoint on purpose: "can I reach Help24"
/// is the question that actually determines whether the app can function, and
/// it is a response we already own and pay nothing for.
/// Decoupling seam between plain networking code and the provider.
///
/// The HTTP layer has no BuildContext and must not depend on the widget tree,
/// but it is exactly where the truth lives: it sees every response and every
/// timeout. This lets it report that truth without either side importing the
/// other's world.
class NetworkHealth {
  NetworkHealth._();
  static void Function()? onSuccess;
  static void Function()? onFailure;

  static void success() => onSuccess?.call();
  static void failure() => onFailure?.call();
}

class ConnectivityProvider extends ChangeNotifier with WidgetsBindingObserver {
  /// [probeUrl] is injectable so the "connected but carrying nothing" case —
  /// an expired data bundle — can be reproduced deterministically in tests by
  /// pointing at an address that refuses instantly. Production always uses the
  /// real health endpoint.
  ConnectivityProvider({String? probeUrl, bool autoStart = true})
      : _probeUrl = probeUrl ?? '${ApiConfig.baseUrl}/health' {
    WidgetsBinding.instance.addObserver(this);
    NetworkHealth.onSuccess = reportSuccess;
    NetworkHealth.onFailure = reportFailure;
    if (autoStart) _start();
  }

  final String _probeUrl;

  static const Duration _probeTimeout = Duration(seconds: 5);
  static const int _failuresBeforeProbe = 2;
  static const Duration _minProbeGap = Duration(seconds: 10);
  static const List<int> _backoffSeconds = [10, 30, 60, 120, 300];

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _retryTimer;

  /// Fires exactly once each time reachability transitions offline → online.
  /// Screens subscribe to this to re-run their own load after the connection
  /// comes back, instead of every screen re-implementing the offline→online
  /// edge detection. Broadcast so any number of screens can listen.
  final StreamController<void> _reconnectController =
      StreamController<void>.broadcast();
  Stream<void> get onReconnect => _reconnectController.stream;

  void _emitReconnect() {
    if (!_reconnectController.isClosed) _reconnectController.add(null);
  }

  /// Interface-level state — a cheap trigger, never the answer on its own.
  bool _hasInterface = true;

  /// Reachability as last evidenced. Optimistic at launch so a healthy start
  /// never flashes an offline banner before the first request resolves.
  bool _reachable = true;
  bool _probing = false;
  int _consecutiveFailures = 0;
  int _backoffIndex = 0;
  DateTime? _lastProbeAt;

  /// True when the app cannot reach Help24 — the flag screens branch on.
  bool get isOffline => !_hasInterface || !_reachable;

  /// Radio up but nothing gets through (expired bundle, captive portal). Lets
  /// copy be specific instead of a generic "no connection".
  bool get isConnectedButUnreachable => _hasInterface && !_reachable;

  bool get isProbing => _probing;

  void _start() {
    Connectivity().checkConnectivity().then(_applyInterface).catchError((Object _) {});
    _subscription = Connectivity().onConnectivityChanged.listen(_applyInterface);
  }

  void _applyInterface(List<ConnectivityResult> results) {
    final has = results.isNotEmpty && results.any((r) => r != ConnectivityResult.none);
    final regained = has && !_hasInterface;
    _hasInterface = has;
    if (!has) {
      // No interface at all is proof enough; don't waste a probe.
      _reachable = false;
      _retryTimer?.cancel();
      notifyListeners();
      return;
    }
    // An interface appeared or changed — the best moment to find out whether
    // it actually carries traffic.
    if (regained || !_reachable) {
      _backoffIndex = 0;
      checkNow();
    } else {
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may have fixed their connection while away, and is about to
    // look at the screen.
    if (state == AppLifecycleState.resumed && isOffline) {
      _backoffIndex = 0;
      checkNow();
    }
  }

  /// Any successful network response — free proof that the internet works.
  void reportSuccess() {
    _consecutiveFailures = 0;
    if (!_reachable) {
      _reachable = true;
      _backoffIndex = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
      notifyListeners();
      _emitReconnect();
    }
  }

  /// A timeout or socket failure. Escalates to a probe rather than flipping
  /// state on the word of a single request.
  void reportFailure() {
    if (!_reachable) return;
    _consecutiveFailures++;
    if (_consecutiveFailures >= _failuresBeforeProbe) checkNow();
  }

  /// Settles the question with one small request. Safe to call often — it
  /// self-throttles and never runs concurrently.
  Future<bool> checkNow() async {
    if (_probing) return _reachable;
    final since = _lastProbeAt;
    if (since != null && DateTime.now().difference(since) < _minProbeGap) {
      return _reachable;
    }
    _probing = true;
    _lastProbeAt = DateTime.now();
    notifyListeners();

    var ok = false;
    try {
      final response = await http.get(Uri.parse(_probeUrl)).timeout(_probeTimeout);
      // Any answer from our server proves the path works; even a 5xx means the
      // packets arrived, which is what this flag is about.
      ok = response.statusCode < 500;
    } on TimeoutException {
      ok = false;
    } on SocketException {
      ok = false;
    } catch (e) {
      debugPrint('ConnectivityProvider probe: $e');
      ok = false;
    }

    _probing = false;
    final changed = ok != _reachable;
    _reachable = ok;
    if (ok) {
      _consecutiveFailures = 0;
      _backoffIndex = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
    } else {
      _scheduleRetry();
    }
    if (changed || !ok) notifyListeners();
    // A probe that flips us from offline back to reachable is a reconnect.
    if (changed && ok) _emitReconnect();
    return ok;
  }

  /// Backoff, not polling: a dead connection settles at one tiny request every
  /// five minutes instead of a constant drip.
  void _scheduleRetry() {
    _retryTimer?.cancel();
    final seconds = _backoffSeconds[_backoffIndex.clamp(0, _backoffSeconds.length - 1)];
    if (_backoffIndex < _backoffSeconds.length - 1) _backoffIndex++;
    _retryTimer = Timer(Duration(seconds: seconds), () {
      if (_hasInterface && !_reachable) checkNow();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (NetworkHealth.onSuccess == reportSuccess) NetworkHealth.onSuccess = null;
    if (NetworkHealth.onFailure == reportFailure) NetworkHealth.onFailure = null;
    _subscription?.cancel();
    _retryTimer?.cancel();
    _reconnectController.close();
    super.dispose();
  }
}
