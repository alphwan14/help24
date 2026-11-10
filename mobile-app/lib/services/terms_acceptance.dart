import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Has this install accepted the CURRENT Terms of Service and Privacy Policy?
///
/// Read once in main() from the SharedPreferences instance that is already
/// loaded before the first frame (the theme reads it there too), so the
/// answer is known synchronously when the first frame is built: no network,
/// no extra wait in the launch transaction (docs: launch transaction contract).
///
/// VERSIONED. [currentVersion] is the date of the terms the app shows. When
/// the terms change in a way people must agree to again (a new fee, a new
/// money rule), bump it: every install that accepted an older version sees
/// the screen once more. Keep it equal to LAST_UPDATED on help24.co.ke/terms.
class TermsAcceptance {
  TermsAcceptance._();

  /// The terms shown in TermsAcceptanceScreen and at help24.co.ke/terms.
  static const String currentVersion = '2026-11-10';

  static const String _versionKey = 'terms_accepted_version';
  static const String _atKey = 'terms_accepted_at';

  static SharedPreferences? _prefs;
  static bool _accepted = false;
  static final Completer<void> _ready = Completer<void>();

  /// Whether the current version is accepted. False until [load] has run.
  static bool get isAccepted => _accepted;

  /// Completes once the current terms are accepted (at once if they already
  /// were). Anything that would open a sheet or a screen on its own at
  /// startup (the location ask, a card link, an explainer) awaits this after
  /// LaunchSequence.ready, so nothing is ever put on top of the terms.
  static Future<void> get ready => _ready.future;

  /// Call once in main(), before runApp, with the preloaded instance.
  static void load(SharedPreferences prefs) {
    _prefs = prefs;
    _accepted = prefs.getString(_versionKey) == currentVersion;
    if (_accepted && !_ready.isCompleted) _ready.complete();
  }

  /// Record acceptance on this device. Returns once it is written, so a
  /// relaunch straight after never shows the screen again.
  static Future<void> accept({DateTime? now}) async {
    _accepted = true;
    if (!_ready.isCompleted) _ready.complete();
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setString(_versionKey, currentVersion);
    await prefs.setString(_atKey, (now ?? DateTime.now()).toUtc().toIso8601String());
  }

  /// When this device accepted the current version, if it has.
  static DateTime? get acceptedAt {
    if (!_accepted) return null;
    final raw = _prefs?.getString(_atKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }
}
