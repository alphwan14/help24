import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/moderation.dart';
import 'session_scope.dart';
import 'supabase_auth_bridge.dart';

/// The signed-in person's Trust & Safety standing, for EXPLANATION only.
///
/// WHAT THIS IS NOT
/// ----------------
/// It is not the enforcement. The database refuses a restricted account's
/// writes (migration 116) and the backend refuses its routes (ModerationGuard);
/// this store exists so the app can say so BEFORE someone types a message or
/// fills in a listing, and say it kindly, with the reason and a way to get
/// help. That is why every failure here fails OPEN: an unreadable status is
/// [AccountStatus.unknown], which denies nothing. A read that fails must never
/// be what locks a person out of their own account.
///
/// Source: `my_account_status()`, which returns only what is the person's own
/// to know — the kind, the reason written for them, the end, a reference.
class AccountStatusStore extends ChangeNotifier implements SessionScoped {
  AccountStatusStore._();

  static final AccountStatusStore instance = AccountStatusStore._();

  /// Key prefix for "restrictions this person has already been shown". Listed
  /// in [SessionScope.uidScopedPrefixes], so it is namespaced and purged.
  static const String ackPrefix = 'help24_moderation_ack_';

  static const Duration _staleAfter = Duration(minutes: 2);
  static const Duration _timeout = Duration(seconds: 12);

  String? _uid;
  AccountStatus _status = AccountStatus.unknown;
  DateTime? _fetchedAt;
  Future<void>? _inFlight;
  Timer? _expiry;
  Set<String> _acknowledged = const {};

  /// Bumped on every bind and reset, so a response for a previous account (or
  /// from before a sign-out) is discarded instead of painted.
  int _generation = 0;

  AccountStatus get status => _status;
  String? get uid => _uid;

  /// True only when the server said so; see the class comment.
  bool denies(String capability) => _status.denies(capability);

  /// A restriction the person has not yet been walked through. The shell
  /// shows the explainer once per restriction, not on every launch.
  AccountRestriction? get unacknowledged {
    final r = _status.primary;
    if (r == null || _acknowledged.contains(r.id)) return null;
    return r;
  }

  /// Start tracking [uid] (empty/null = signed out). Idempotent.
  Future<void> bind(String? uid) async {
    final next = (uid == null || uid.isEmpty) ? null : uid;
    if (next == _uid) return;
    _reset(notify: false);
    _uid = next;
    notifyListeners();
    if (next == null) return;
    await _loadAcknowledged(next);
    await refresh();
  }

  /// Re-read from the server. Single-flight: concurrent callers share one read.
  Future<void> refresh() {
    if (_uid == null) return Future.value();
    return _inFlight ??= _read().whenComplete(() => _inFlight = null);
  }

  /// Refresh when the last good read is older than [maxAge] (resume, screen open).
  Future<void> refreshIfStale({Duration maxAge = _staleAfter}) {
    final at = _fetchedAt;
    if (at != null && DateTime.now().difference(at) < maxAge) return Future.value();
    return refresh();
  }

  /// Record that the person has seen the explainer for what is in force now.
  Future<void> acknowledge() async {
    final uid = _uid;
    if (uid == null) return;
    final ids = {..._acknowledged, for (final r in _status.restrictions) r.id};
    // Only ids still in force are worth remembering.
    ids.retainWhere((id) => _status.restrictions.any((r) => r.id == id));
    _acknowledged = ids;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(SessionScope.scopedKey(ackPrefix, uid), ids.toList());
    } catch (e) {
      debugPrint('[ACCOUNT_STATUS] could not persist acknowledgement: $e');
    }
  }

  Future<void> _read() async {
    final generation = _generation;
    try {
      await SupabaseAuthBridge.ensureSessionAsync();
      final raw = await Supabase.instance.client.rpc('my_account_status').timeout(_timeout);
      if (generation != _generation) return; // signed out / switched meanwhile
      final parsed = AccountStatus.fromJson(raw);
      // An `unknown` answer (no identity on the request) is not news: keep what
      // we had rather than flicker a restricted person back to "active".
      if (!parsed.isKnown) return;
      _fetchedAt = DateTime.now();
      _apply(parsed);
    } catch (e) {
      // Fail open — the server still enforces. Before migration 114 is applied
      // the function does not exist, and this is the path every read takes.
      debugPrint('[ACCOUNT_STATUS] read failed (status stays ${_status.standing.name}): $e');
    }
  }

  void _apply(AccountStatus next) {
    final changed = next.standing != _status.standing ||
        !setEquals(next.deniedCapabilities, _status.deniedCapabilities) ||
        next.restrictions.length != _status.restrictions.length ||
        next.warnings.length != _status.warnings.length ||
        !_sameIds(next, _status);
    _status = next;
    _armExpiry(next);
    if (changed) notifyListeners();
  }

  /// When the soonest restriction ends, look again — so a suspension that
  /// expires while the app is open lifts in the UI without a restart. Timed
  /// against the SERVER's clock at read time, not the phone's.
  void _armExpiry(AccountStatus s) {
    _expiry?.cancel();
    _expiry = null;
    final now = s.serverTime;
    if (now == null) return;
    Duration? soonest;
    for (final r in s.restrictions) {
      final end = r.endsAt;
      if (end == null) continue;
      final left = end.difference(now);
      if (soonest == null || left < soonest) soonest = left;
    }
    if (soonest == null) return;
    // A little after the end, so the read lands on the far side of it. Timers
    // do not run while the process is suspended; resume refreshes cover that.
    final wait = soonest.isNegative ? const Duration(seconds: 5) : soonest + const Duration(seconds: 5);
    if (wait > const Duration(days: 2)) return;
    _expiry = Timer(wait, () => unawaited(refresh()));
  }

  Future<void> _loadAcknowledged(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _acknowledged = (prefs.getStringList(SessionScope.scopedKey(ackPrefix, uid)) ?? const []).toSet();
    } catch (_) {
      _acknowledged = const {};
    }
  }

  static bool _sameIds(AccountStatus a, AccountStatus b) {
    final x = a.restrictions.map((r) => r.id).toSet();
    final y = b.restrictions.map((r) => r.id).toSet();
    return setEquals(x, y);
  }

  void _reset({required bool notify}) {
    _generation++;
    _expiry?.cancel();
    _expiry = null;
    _inFlight = null;
    _uid = null;
    _status = AccountStatus.unknown;
    _fetchedAt = null;
    _acknowledged = const {};
    if (notify) notifyListeners();
  }

  @override
  void resetForSignOut() => _reset(notify: true);

  /// Test seam: install a status as if it had been read.
  @visibleForTesting
  void debugSet(String uid, AccountStatus status) {
    _uid = uid;
    _fetchedAt = DateTime.now();
    _apply(status);
  }
}
