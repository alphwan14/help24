import 'dart:async';

import 'package:flutter/foundation.dart';

import 'location_service.dart';

/// Human place names for coordinates ("Mtopanga", "Nyali", "Bamburi").
///
/// Reverse geocoding is used ONLY where a name beats a number — naming a
/// journey's destination. It is never used for the traveller's moving position
/// (that would geocode on every fix for no benefit) and never blocks the UI.
///
/// Aggressive caching is the whole point:
///   • keyed by coordinates rounded to ~11 m, so a destination resolves once;
///   • in-flight requests are shared, so a rebuild storm is one lookup;
///   • failures are cached as "no name" for a while, so a dead geocoder is not
///     retried on every rebuild;
///   • results are kept for the process lifetime — place names do not move.
///
/// This uses the on-device platform geocoder via the existing `geocoding`
/// package (already a dependency for post creation). It is NOT the billable
/// Google Geocoding API — Phase 3 adds no new billable surface beyond Routes.
class PlaceNameCache {
  PlaceNameCache._();

  static final Map<String, String?> _names = {};
  static final Map<String, Future<String?>> _inFlight = {};
  static final Map<String, DateTime> _failedAt = {};
  static const Duration _failureCooldown = Duration(minutes: 10);

  static String _key(double lat, double lng) =>
      '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';

  /// Cached name if we already have one — synchronous, safe to call in build().
  static String? peek(double lat, double lng) => _names[_key(lat, lng)];

  /// Resolves a place name, or null. Never throws, never blocks meaningfully.
  static Future<String?> resolve(double lat, double lng) {
    final key = _key(lat, lng);
    if (_names.containsKey(key)) return Future.value(_names[key]);

    final failed = _failedAt[key];
    if (failed != null && DateTime.now().difference(failed) < _failureCooldown) {
      return Future.value(null);
    }
    final existing = _inFlight[key];
    if (existing != null) return existing;

    // Block body, NOT `whenComplete(() => _inFlight.remove(key))`. The arrow
    // form returns Map.remove's value — the very future stored on the next
    // line — and whenComplete awaits any Future its callback returns, so the
    // future ends up awaiting itself and never completes. The lookup succeeds,
    // nothing throws, and every caller's `await` hangs: on the journey confirm
    // screen the destination area name simply never appeared, silently.
    final future = _lookup(lat, lng, key).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  static Future<String?> _lookup(double lat, double lng, String key) async {
    try {
      final name = await LocationService.getCityFromCoordinates(
        latitude: lat,
        longitude: lng,
      ).timeout(const Duration(seconds: 5));
      if (name != null && name.trim().isNotEmpty) {
        _names[key] = name.trim();
        return _names[key];
      }
      // Resolved to nothing: remember it so we do not ask again.
      _names[key] = null;
      return null;
    } catch (e) {
      debugPrint('PlaceNameCache: $e');
      _failedAt[key] = DateTime.now();
      return null;
    }
  }
}
