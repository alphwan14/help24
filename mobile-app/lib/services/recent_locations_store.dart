import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/place.dart';
import 'session_scope.dart';

/// The last few locations this person actually posted from.
///
/// Uber and Bolt do not make you search for home every time, and neither
/// should Help24: a provider works the same three or four areas, and after one
/// post those become one tap. This is the cheapest possible version of that —
/// device-only, no backend, no API, no sync.
///
/// SESSION-SCOPED ON PURPOSE
/// -------------------------
/// Where a person posts from is theirs, not the device's. The store registers
/// with [SessionScope] so signing out clears it, exactly like every other
/// user-owned cache — a shared phone must never suggest the previous account's
/// neighbourhood.
class RecentLocationsStore implements SessionScoped {
  RecentLocationsStore._() {
    SessionScope.instance.register(this);
  }
  static final RecentLocationsStore instance = RecentLocationsStore._();

  static const String _key = 'help24_recent_locations_v1';
  static const int _max = 5;

  List<LocationSelection> _cache = const [];
  bool _loaded = false;

  /// Synchronous snapshot — safe in build(). Empty until [load] has run once,
  /// which is fine: the recents strip simply is not there for one frame.
  List<LocationSelection> get cached => _cache;

  Future<List<LocationSelection>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      _loaded = true;
      if (raw == null) return _cache = const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return _cache = const [];
      return _cache = decoded
          .map(LocationSelection.fromJson)
          .whereType<LocationSelection>()
          .toList();
    } catch (e) {
      debugPrint('RecentLocationsStore load: $e');
      _loaded = true;
      return _cache = const [];
    }
  }

  /// Records a choice as most-recent. De-duplicated by label so re-posting from
  /// the same area promotes it rather than filling the list with copies.
  /// Never throws — a failed write must not block a post the user committed to.
  Future<void> add(LocationSelection selection) async {
    try {
      if (!_loaded) await load();
      final key = selection.label.trim().toLowerCase();
      if (key.isEmpty) return;
      final next = <LocationSelection>[
        selection,
        ..._cache.where((s) => s.label.trim().toLowerCase() != key),
      ].take(_max).toList();
      _cache = next;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(next.map((s) => s.toJson()).toList()));
    } catch (e) {
      debugPrint('RecentLocationsStore add: $e');
    }
  }

  @override
  void resetForSignOut() {
    _cache = const [];
    _loaded = false;
    // The key itself is removed by SessionScope's purge; clearing the in-memory
    // mirror here is what stops the next account seeing it before that lands.
    SharedPreferences.getInstance()
        .then((p) => p.remove(_key))
        .catchError((Object e) {
      debugPrint('RecentLocationsStore clear: $e');
      return false;
    });
  }
}
