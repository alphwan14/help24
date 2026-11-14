import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_model.dart';

/// The last known profile and setup facts, so Profile paints complete on its
/// first frame.
///
/// Profile used to open from the signed-in user alone and then grow: the
/// professional row, the Business rows and "Get ready to work" each arrived a
/// moment later, as their reads came back. Now the screen opens from the last
/// answers this phone saw, held in memory and in SharedPreferences (loaded
/// before the first frame in main.dart, so reading it is synchronous), and
/// fresh reads replace them in place. Only a phone that has never opened the
/// app as this account waits for the network.
///
/// Keyed by account and cleared on sign-out: nobody else signing in on the
/// phone sees this account's profile.
class ProfileSnapshotCache {
  ProfileSnapshotCache._();

  static SharedPreferences? _prefs;
  static final Map<String, Map<String, dynamic>> _rows = {};
  static final Map<String, ProfileSetupFacts> _setup = {};

  static const _rowPrefix = 'profile_row_v1_';
  static const _setupPrefix = 'profile_setup_v1_';

  /// Called once in main.dart with the preferences it already loaded.
  static void load(SharedPreferences prefs) => _prefs = prefs;

  /// The last profile this phone saw for [uid], or null.
  static UserModel? user(String uid) {
    if (uid.isEmpty) return null;
    final row = _rows[uid] ?? _decode(_prefs?.getString('$_rowPrefix$uid'));
    if (row == null) return null;
    _rows[uid] = row;
    try {
      return UserModel.fromSupabase(row);
    } catch (e) {
      debugPrint('ProfileSnapshotCache: stored profile unreadable ($e)');
      return null;
    }
  }

  static void rememberRow(String uid, Map<String, dynamic> row) {
    if (uid.isEmpty) return;
    _rows[uid] = row;
    try {
      _prefs?.setString('$_rowPrefix$uid', jsonEncode(row));
    } catch (_) {
      // A value JSON cannot hold: the memory copy still serves this session.
    }
  }

  static ProfileSetupFacts? setup(String uid) {
    if (uid.isEmpty) return null;
    final hit = _setup[uid];
    if (hit != null) return hit;
    final map = _decode(_prefs?.getString('$_setupPrefix$uid'));
    if (map == null) return null;
    final facts = ProfileSetupFacts(
      idVerified: map['idVerified'] as bool?,
      hasPayout: map['hasPayout'] as bool?,
      payoutAvailable: map['payoutAvailable'] as bool? ?? true,
    );
    return _setup[uid] = facts;
  }

  static void rememberSetup(String uid, ProfileSetupFacts facts) {
    if (uid.isEmpty) return;
    _setup[uid] = facts;
    _prefs?.setString(
      '$_setupPrefix$uid',
      jsonEncode({
        'idVerified': facts.idVerified,
        'hasPayout': facts.hasPayout,
        'payoutAvailable': facts.payoutAvailable,
      }),
    );
  }

  /// Forget every account's snapshot (sign-out).
  static Future<void> clear() async {
    _rows.clear();
    _setup.clear();
    final prefs = _prefs;
    if (prefs == null) return;
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith(_rowPrefix) || key.startsWith(_setupPrefix)) {
        await prefs.remove(key);
      }
    }
  }

  static Map<String, dynamic>? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }
}

/// The two setup facts the profile row does not carry, plus whether payouts
/// exist in this build at all.
@immutable
class ProfileSetupFacts {
  const ProfileSetupFacts({this.idVerified, this.hasPayout, this.payoutAvailable = true});

  final bool? idVerified;
  final bool? hasPayout;
  final bool payoutAvailable;
}
