import 'dart:math' as math;

/// Distance between a viewer and a listing — the SINGLE definition.
///
/// WHY THIS FILE EXISTS
/// --------------------
/// The same haversine was written twice by hand: once in `AppProvider` to sort
/// urgent posts by proximity, once in `UrgentRequestsScreen` to label them. Two
/// copies of one formula is two chances to drift, and the screen's copy existed
/// only because the provider's was private.
///
/// Pure Dart — no Flutter, no network — so the rules are unit-testable and every
/// surface measures distance the same way.

const double _earthRadiusKm = 6371.0;

double _degToRad(double deg) => deg * (math.pi / 180.0);

/// Great-circle distance in kilometres.
double distanceKm(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _degToRad(lat2 - lat1);
  final dLon = _degToRad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_degToRad(lat1)) *
          math.cos(_degToRad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return _earthRadiusKm * c;
}

/// Distance between a viewer and a listing, or null when either side has no
/// coordinates.
///
/// Null is the honest answer for "we don't know", and callers render it as
/// "Nearby" rather than inventing a number — the same null-means-not-applicable
/// rule the ranking engine's signals follow.
double? distanceBetween({
  double? viewerLatitude,
  double? viewerLongitude,
  double? targetLatitude,
  double? targetLongitude,
}) {
  if (viewerLatitude == null ||
      viewerLongitude == null ||
      targetLatitude == null ||
      targetLongitude == null) {
    return null;
  }
  return distanceKm(
      viewerLatitude, viewerLongitude, targetLatitude, targetLongitude);
}

/// Human distance label: "400 m away", "1.2 km away", "18 km away".
///
/// Metres below a kilometre (someone deciding whether to walk needs that
/// precision), one decimal up to 10 km, whole kilometres beyond — a tenth of a
/// kilometre is noise at that range.
String formatDistanceLabel(double km) {
  if (km < 1) {
    // Rounded to 10 m: GPS is not accurate to the metre and "417 m away" claims
    // a precision the fix does not have.
    final metres = (km * 1000 / 10).round() * 10;
    return '$metres m away';
  }
  if (km < 10) return '${km.toStringAsFixed(1)} km away';
  return '${km.round()} km away';
}

/// [formatDistanceLabel] for an optional distance — null when unknown, so the
/// caller can fall back to "Nearby" without repeating the null check.
String? formatDistanceLabelOrNull(double? km) =>
    km == null ? null : formatDistanceLabel(km);
