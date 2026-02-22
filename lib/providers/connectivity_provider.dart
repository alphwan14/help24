import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Exposes [isOffline]. When true, UI can show cached data and offline banner.
/// Listens to [Connectivity().onConnectivityChanged] and treats [none] as offline.
class ConnectivityProvider extends ChangeNotifier {
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _isOffline = false;

  bool get isOffline => _isOffline;

  ConnectivityProvider() {
    _init();
  }

  Future<void> _init() async {
    await _updateFromConnectivity();
    _subscription = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      _updateFromResults(results);
    });
  }

  Future<void> _updateFromConnectivity() async {
    try {
      final results = await Connectivity().checkConnectivity();
      _updateFromResults(results);
    } catch (e) {
      debugPrint('ConnectivityProvider: $e');
      _isOffline = true;
      notifyListeners();
    }
  }

  void _updateFromResults(List<ConnectivityResult> results) {
    final wasOffline = _isOffline;
    _isOffline = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (_isOffline != wasOffline) notifyListeners();
  }

  /// Manual refresh of connectivity state (e.g. after retry).
  Future<void> checkNow() async {
    await _updateFromConnectivity();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
