import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One place the user has pinned before — coordinates plus their own label.
@immutable
class RecentPlace {
  final double latitude;
  final double longitude;
  final String label;
  final DateTime savedAt;

  const RecentPlace({
    required this.latitude,
    required this.longitude,
    required this.label,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
        'lat': latitude,
        'lng': longitude,
        'label': label,
        'at': savedAt.toIso8601String(),
      };

  static RecentPlace? fromJson(Map<String, dynamic> j) {
    final lat = j['lat'], lng = j['lng'];
    if (lat is! num || lng is! num) return null;
    return RecentPlace(
      latitude: lat.toDouble(),
      longitude: lng.toDouble(),
      label: (j['label'] as String?)?.trim() ?? '',
      savedAt: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

/// Recently pinned places, stored ON THE DEVICE ONLY.
///
/// Deliberately zero-cost and zero-backend: this is the free alternative to
/// Places search that the product decision called for. It never touches the
/// network, never syncs, and reuses SharedPreferences (already a dependency).
/// A user's frequent spots — the gate, the office, the apartment — become one
/// tap to re-pin without any recurring API bill.
///
/// Bounded and de-duplicated so it stays a short, useful list rather than an
/// ever-growing history: re-pinning the same spot moves it to the top instead
/// of adding a near-duplicate row.
class RecentPlacesStore {
  RecentPlacesStore._();

  static const String _key = 'recent_places.v1';
  static const int _maxEntries = 6;
  // ~11 m: two pins closer than this with the same label are "the same place".
  static const int _dedupeDp = 4;

  /// In-memory cache so the picker can render instantly on open without an
  /// async gap; refreshed on every load/save.
  static List<RecentPlace> _cache = const [];
  static bool _loaded = false;

  /// Synchronously readable snapshot (may be empty before the first [load]).
  static List<RecentPlace> get cached => _cache;

  static Future<List<RecentPlace>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) {
        _loaded = true;
        return _cache = const [];
      }
      final list = (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(RecentPlace.fromJson)
          .whereType<RecentPlace>()
          .toList();
      _loaded = true;
      return _cache = list;
    } catch (e) {
      debugPrint('RecentPlacesStore load: $e');
      _loaded = true;
      return _cache = const [];
    }
  }

  static String _dedupeKey(double lat, double lng, String label) =>
      '${lat.toStringAsFixed(_dedupeDp)},${lng.toStringAsFixed(_dedupeDp)}'
      '|${label.trim().toLowerCase()}';

  /// Records a pinned place as most-recent. Idempotent on the same spot+label,
  /// bounded to [_maxEntries]. Never throws — a failed write must not block a
  /// send the user already committed to.
  static Future<void> add({
    required double latitude,
    required double longitude,
    required String label,
  }) async {
    try {
      if (!_loaded) await load();
      final entry = RecentPlace(
        latitude: latitude,
        longitude: longitude,
        label: label.trim(),
        savedAt: DateTime.now(),
      );
      final key = _dedupeKey(latitude, longitude, entry.label);
      final next = <RecentPlace>[
        entry,
        ..._cache.where((p) => _dedupeKey(p.latitude, p.longitude, p.label) != key),
      ].take(_maxEntries).toList();
      _cache = next;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(next.map((p) => p.toJson()).toList()));
    } catch (e) {
      debugPrint('RecentPlacesStore add: $e');
    }
  }
}
