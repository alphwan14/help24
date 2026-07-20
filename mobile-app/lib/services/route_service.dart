import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';

/// One computed route: ETA, remaining distance and the drawable path.
@immutable
class JourneyRoute {
  final int durationSeconds;
  final int distanceMeters;
  /// Decoded path, origin → destination. Empty when the server returned no
  /// polyline (still a usable ETA).
  final List<({double lat, double lng})> path;
  /// When this route was computed — drives staleness, so an ETA is never
  /// presented as fresher than it is.
  final DateTime computedAt;

  const JourneyRoute({
    required this.durationSeconds,
    required this.distanceMeters,
    required this.path,
    required this.computedAt,
  });

  /// ETA counted down by elapsed time. Between refreshes the number keeps
  /// falling instead of freezing, which is what makes it feel live — and it
  /// costs nothing. Never counts below zero.
  int get liveDurationSeconds {
    final elapsed = DateTime.now().difference(computedAt).inSeconds;
    final remaining = durationSeconds - elapsed;
    return remaining < 0 ? 0 : remaining;
  }

  /// Past this age an ETA is not worth showing at all.
  bool get isStale =>
      DateTime.now().difference(computedAt) > const Duration(minutes: 5);
}

/// Client for the backend's Routes proxy (`POST /routes/compute`).
///
/// The billable key lives on the server (Routes is a web service and cannot be
/// locked to an Android package + SHA-1). This client's job is to ask for a
/// route as *rarely* as possible while still feeling live:
///
///   • a short-lived in-memory cache keyed by rounded coordinates;
///   • single-flight, so concurrent callers share one request;
///   • all pacing decisions (how far / how often) live in [shouldRefresh].
///
/// Every failure resolves to null. An ETA is an enhancement layered on the
/// Phase 2 journey; when it is unavailable the journey is unchanged.
class RouteService {
  RouteService._();

  static final Map<String, ({JourneyRoute route, DateTime at})> _cache = {};
  static final Map<String, Future<JourneyRoute?>> _inFlight = {};
  static const Duration _cacheTtl = Duration(seconds: 45);

  /// Refresh policy — the cost lever. A route is only worth recomputing when
  /// the picture has actually changed:
  ///
  ///   • no route yet                         → fetch
  ///   • moved [_refreshDistanceM] since last → fetch (real progress)
  ///   • [_refreshInterval] elapsed           → fetch (traffic drift)
  ///   • close to the destination             → fetch a little more eagerly,
  ///     because the last minute is when the number matters most
  ///
  /// A stationary traveller therefore costs one call per interval, not one per
  /// GPS fix.
  static const double _refreshDistanceM = 250;
  static const Duration _refreshInterval = Duration(seconds: 90);
  static const Duration _nearbyRefreshInterval = Duration(seconds: 45);
  static const double _nearbyThresholdM = 1500;

  static bool shouldRefresh({
    required JourneyRoute? current,
    required double? lastFetchLat,
    required double? lastFetchLng,
    required double nowLat,
    required double nowLng,
    required double? straightLineToDestM,
  }) {
    if (current == null || lastFetchLat == null || lastFetchLng == null) {
      return true;
    }
    final moved = Geolocator.distanceBetween(
        lastFetchLat, lastFetchLng, nowLat, nowLng);
    if (moved >= _refreshDistanceM) return true;

    final age = DateTime.now().difference(current.computedAt);
    final near = straightLineToDestM != null &&
        straightLineToDestM <= _nearbyThresholdM;
    return age >= (near ? _nearbyRefreshInterval : _refreshInterval);
  }

  static String _key(double oLat, double oLng, double dLat, double dLng) =>
      '${oLat.toStringAsFixed(4)},${oLng.toStringAsFixed(4)}'
      '>${dLat.toStringAsFixed(5)},${dLng.toStringAsFixed(5)}';

  /// Fetches a route, or null when unavailable. Never throws.
  static Future<JourneyRoute?> compute({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
  }) {
    final key = _key(originLat, originLng, destLat, destLng);

    final cached = _cache[key];
    if (cached != null && DateTime.now().difference(cached.at) < _cacheTtl) {
      return Future.value(cached.route);
    }
    // Single-flight: a rebuild storm must not become a request storm.
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _fetch(originLat, originLng, destLat, destLng, key)
        .whenComplete(() => _inFlight.remove(key));
    _inFlight[key] = future;
    return future;
  }

  static Future<JourneyRoute?> _fetch(
    double originLat,
    double originLng,
    double destLat,
    double destLng,
    String key,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse(ApiConfig.routesCompute),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'originLat': originLat,
              'originLng': originLng,
              'destLat': destLat,
              'destLng': destLng,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        debugPrint('RouteService: HTTP ${response.statusCode}');
        return null;
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['available'] != true) {
        // Expected, not exceptional: key unconfigured, no route, quota.
        debugPrint('RouteService: unavailable (${body['reason']})');
        return null;
      }
      final duration = body['durationSeconds'];
      final distance = body['distanceMeters'];
      if (duration is! num || distance is! num) return null;

      final route = JourneyRoute(
        durationSeconds: duration.round(),
        distanceMeters: distance.round(),
        path: decodePolyline(body['polyline'] as String?),
        computedAt: DateTime.now(),
      );
      _cache[key] = (route: route, at: DateTime.now());
      if (_cache.length > 40) _cache.remove(_cache.keys.first);
      return route;
    } catch (e) {
      debugPrint('RouteService: $e');
      return null;
    }
  }

  /// Google's encoded-polyline format → points. Pure and dependency-free, so
  /// no extra package is added for ~30 lines of well-specified decoding.
  static List<({double lat, double lng})> decodePolyline(String? encoded) {
    if (encoded == null || encoded.isEmpty) return const [];
    final points = <({double lat, double lng})>[];
    int index = 0, lat = 0, lng = 0;

    /// Reads one zig-zag varint, or null if the payload ends mid-value.
    /// The bounds check must happen BEFORE each read: a truncated response
    /// (interrupted download, upstream clipping) would otherwise index past
    /// the end and throw.
    int? readVarint() {
      int result = 0, shift = 0, b;
      do {
        if (index >= encoded.length) return null;
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      return (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    }

    while (index < encoded.length) {
      final dLat = readVarint();
      if (dLat == null) break; // truncated — keep the points decoded so far
      final dLng = readVarint();
      if (dLng == null) break;
      lat += dLat;
      lng += dLng;
      points.add((lat: lat / 1e5, lng: lng / 1e5));
    }
    return points;
  }
}
