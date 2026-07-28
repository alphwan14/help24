import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/place.dart';
import 'location_registry.dart';
import 'location_service.dart';

/// Why "Use current location" could not produce a place. Each value maps to a
/// DIFFERENT thing the user can do about it, which is the only reason to
/// distinguish them — a single "location failed" message would be useless.
enum CurrentLocationFailure {
  /// Permission refused this time. Asking again is legitimate.
  permissionDenied,

  /// Permission refused permanently — only Settings can fix it.
  permissionBlocked,

  /// App has permission but the device's location toggle is off.
  serviceDisabled,

  /// Permission and service are fine, no fix arrived (indoors, cold start).
  noFix,

  /// A fix arrived but it was too coarse to name a neighbourhood with — a
  /// kilometre-wide circle spans several of them. Distinguished from [noFix]
  /// because the user's remedy is different: move to open sky, or pick a town.
  lowAccuracy,

  /// We have a coordinate but nothing could name it: no geocoder answer AND
  /// no known town within range. Rare, and the coordinate is still returned.
  unnamed,
}

/// The outcome of a "use my location" tap. Exactly one of [selection] and
/// [failure] is non-null, except for [CurrentLocationFailure.unnamed] where a
/// coordinate exists but has no name.
@immutable
class CurrentLocationResult {
  final LocationSelection? selection;
  final CurrentLocationFailure? failure;
  final double? latitude;
  final double? longitude;

  const CurrentLocationResult._({
    this.selection,
    this.failure,
    this.latitude,
    this.longitude,
  });

  const CurrentLocationResult.success(LocationSelection value)
      : this._(selection: value);

  const CurrentLocationResult.failed(
    CurrentLocationFailure reason, {
    double? latitude,
    double? longitude,
  }) : this._(failure: reason, latitude: latitude, longitude: longitude);

  bool get isSuccess => selection != null;

  /// One sentence the UI can show verbatim. Every one of them tells the user
  /// that picking a town manually still works — the manual path is never
  /// blocked by a location failure.
  String get message => switch (failure) {
        CurrentLocationFailure.permissionDenied =>
          'Location permission is off. Allow it, or pick your town below.',
        CurrentLocationFailure.permissionBlocked =>
          'Location is blocked in Settings. Turn it on there, or pick your town below.',
        CurrentLocationFailure.serviceDisabled =>
          'Your device location is switched off. Turn it on, or pick your town below.',
        CurrentLocationFailure.noFix =>
          "Couldn't get a GPS fix. Move to an open area, or pick your town below.",
        CurrentLocationFailure.lowAccuracy =>
          "Your location isn't precise enough to place you yet. Move to an open "
              'area and try again, or pick your town below.',
        CurrentLocationFailure.unnamed =>
          "We got your position but couldn't name it. Pick the closest town below.",
        null => '',
      };
}

/// Turns a GPS fix into a named, postable location.
///
/// THE FALLBACK LADDER (each rung works when the one above it does not)
/// --------------------------------------------------------------------
///   1. reverse geocode → "Nyali, Mombasa"          — best, needs network
///   2. snap to the nearest registry town → "Voi"   — WORKS FULLY OFFLINE
///   3. return the coordinate unnamed               — caller keeps the pin,
///                                                    user names it manually
///
/// Rung 2 is the reason this feels reliable in Kenya rather than in a demo:
/// the platform geocoder needs data, and a bundled dataset of every town with
/// a coordinate does not. A provider standing in Naivasha with no bundle still
/// gets "Naivasha", not a spinner.
///
/// A geocoded name is also RECONCILED against the registry: when the geocoder
/// says "Nyali" and the registry knows Nyali, the canonical entry wins so the
/// stored label matches what the city filter searches for. Vocabulary drift
/// between what GPS writes and what filters read is the bug this prevents.
class CurrentLocationService {
  CurrentLocationService._();

  /// Resolve the device's current location into a [LocationSelection].
  ///
  /// [requestPermission] false makes this entirely silent — used to prefill a
  /// form without ever showing an OS dialog the user did not ask for.
  static Future<CurrentLocationResult> resolve({
    bool requestPermission = true,
  }) async {
    // ── Permission ─────────────────────────────────────────────────────────
    var status = await LocationService.permissionStatus();
    if (!status.isGranted) {
      if (!requestPermission) {
        return CurrentLocationResult.failed(
          status.isPermanentlyDenied
              ? CurrentLocationFailure.permissionBlocked
              : CurrentLocationFailure.permissionDenied,
        );
      }
      await LocationService.requestPermission();
      status = await LocationService.permissionStatus();
      if (!status.isGranted) {
        return CurrentLocationResult.failed(
          status.isPermanentlyDenied
              ? CurrentLocationFailure.permissionBlocked
              : CurrentLocationFailure.permissionDenied,
        );
      }
    }

    // ── Device service toggle ──────────────────────────────────────────────
    if (!await LocationService.isServiceEnabled()) {
      return const CurrentLocationResult.failed(
          CurrentLocationFailure.serviceDisabled);
    }

    // ── Fix ────────────────────────────────────────────────────────────────
    //
    // Waits for a fix good enough to name a neighbourhood with, instead of
    // accepting whatever the platform offers first. See
    // LocationService.getPreciseFix — the old behaviour took a cached,
    // kilometre-wide network estimate and stored it as the user's position.
    final pos = await LocationService.getPreciseFix(requestIfNeeded: false);
    if (pos == null) {
      // getPreciseFix returns null both when nothing arrived and when what
      // arrived was too coarse to trust. Distinguish them for the user with a
      // single cheap read of the last known position: if the platform HAS a
      // position but our gate rejected it, the honest message is "not precise
      // enough", not "no GPS".
      final anyFix = await _lastKnownOrNull();
      return CurrentLocationResult.failed(
        anyFix == null
            ? CurrentLocationFailure.noFix
            : CurrentLocationFailure.lowAccuracy,
      );
    }

    final selection = await describe(
      pos.latitude,
      pos.longitude,
      accuracyMeters: pos.accuracy,
    );
    if (selection == null) {
      return CurrentLocationResult.failed(
        CurrentLocationFailure.unnamed,
        latitude: pos.latitude,
        longitude: pos.longitude,
      );
    }
    return CurrentLocationResult.success(selection);
  }

  /// Whether the platform has any position at all, however poor. Used only to
  /// tell "no signal" apart from "signal too vague" in the failure message.
  static Future<Position?> _lastKnownOrNull() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  /// How much further than the CLOSEST known place a geocoded neighbourhood may
  /// be and still be believed.
  ///
  /// Neighbourhood plausibility cannot be an absolute distance. Kisauni and
  /// Nyali sit 2.4 km apart, so any threshold loose enough for a large estate
  /// is loose enough to accept the estate next door — which is the reported
  /// bug. The honest test is comparative: if the geocoder says "Nyali" but
  /// Kisauni's centre is nearer to this fix than Nyali's is, the fix is in
  /// Kisauni.
  ///
  /// The tolerance exists because these are centroids, not polygons. Within a
  /// kilometre of a tie the two answers are genuinely ambiguous, and the
  /// geocoder — which does have polygons — is the better authority.
  static const double _areaTieToleranceKm = 1.0;

  /// Fallback allowance for a neighbourhood when the registry has nothing
  /// nearby to compare against.
  static const double _maxAreaNameDriftKm = 3.5;

  /// The allowance for a CITY or TOWN name, which is absolute rather than
  /// comparative. Cities are legitimately large: a fix in Kayole is 15 km from
  /// the point labelled "Nairobi" and is still correctly in Nairobi, and the
  /// fact that a nearer neighbourhood exists does not make the city wrong.
  /// Matches the registry's own snapping radius.
  static const double _maxCityNameDriftKm = 25;

  /// Names a coordinate the caller already has (a map pin, a stored fix).
  /// Same ladder as [resolve], without any permission or GPS work.
  ///
  /// THE LADDER
  /// ----------
  ///   1. reverse geocode, then take the MOST SPECIFIC name that the registry
  ///      recognises AND that is geographically consistent with the fix;
  ///   2. snap to the nearest known place — works fully offline;
  ///   3. keep the geocoder's raw name, even though nothing recognised it;
  ///   4. return the coordinate unnamed.
  ///
  /// Rung 1's consistency check is new, and it is the fix for the reported bug.
  /// The old ladder accepted whatever the geocoder said as long as the registry
  /// had heard of the name, with no test that the named place was anywhere near
  /// the coordinate — so a coarse `subLocality` polygon could relabel a phone
  /// standing several kilometres away.
  ///
  /// Whatever rung answers, the COORDINATES returned are always the ones passed
  /// in. The name is a label; distance is never computed from it.
  static Future<LocationSelection?> describe(
    double latitude,
    double longitude, {
    double? accuracyMeters,
  }) async {
    final registry = LocationRegistry.instance;
    await registry.ensureBundled();

    final geo = await LocationService.reverseGeocode(
      latitude: latitude,
      longitude: longitude,
    );

    LocationSelection decorate(LocationSelection base, LocationSource source) =>
        base.copyWith(
          latitude: latitude,
          longitude: longitude,
          source: source,
          county: geo?.county,
          subCounty: geo?.subCounty,
          ward: geo?.ward,
          locality: geo?.locality,
          formattedAddress: geo?.formattedAddress,
          accuracyMeters: accuracyMeters,
        );

    // Rung 1 — the geocoder, reconciled against the vocabulary AND checked
    // against the map. Walks names most-specific-first so the constituency
    // ("Kisauni") is preferred over the coarse sub-locality polygon that
    // contains the fix, and over the city.
    if (geo != null) {
      for (final name in geo.namesBySpecificity) {
        final match = registry.resolveLabel(name);
        if (match == null) continue;
        if (!_isPlausibleFor(match, latitude, longitude)) {
          debugPrint('[CURRENT_LOCATION] rejected "$name" → ${match.id}: '
              'named place is not where this fix is');
          continue;
        }
        return decorate(
          LocationSelection(
            label: match.storageLabel,
            cityName: match.cityName,
            areaName: match.areaName,
            placeId: match.id,
          ),
          LocationSource.gps,
        );
      }
    }

    // Rung 2 — snap to the nearest known place. Reached when the geocoder was
    // silent AND when everything it said failed the consistency check, which is
    // the case that used to produce a confidently wrong neighbourhood.
    final near = registry.nearest(latitude, longitude);
    if (near != null) {
      debugPrint('[CURRENT_LOCATION] snapped to ${near.id}');
      return decorate(
        LocationSelection(
          label: near.storageLabel,
          cityName: near.cityName,
          areaName: near.areaName,
          placeId: near.id,
        ),
        LocationSource.gpsSnapped,
      );
    }

    // Rung 3 — the geocoder named somewhere the registry has never heard of.
    // That is a real place and a perfectly good post location: keep the user's
    // truth rather than snapping them to a town they are not in.
    if (geo != null) {
      return decorate(
        LocationSelection(
          label: geo.label,
          cityName: geo.city,
          areaName: geo.area,
        ),
        LocationSource.gps,
      );
    }

    // Rung 4 — nothing could name it.
    return null;
  }

  /// Whether [place] can plausibly be where this coordinate is.
  ///
  /// A place with no coordinate of its own cannot be contradicted, so it is
  /// accepted — that is the honest answer, and it keeps a correct geocoder
  /// reply working for the parts of the dataset that carry no position.
  ///
  /// A NEIGHBOURHOOD with a coordinate is judged comparatively: it has to be at
  /// least as close to the fix as the nearest place we know about, give or take
  /// [_areaTieToleranceKm]. That is the rule that separates Kisauni from Nyali,
  /// and no absolute threshold can — they are 2.4 km apart, closer than some
  /// single estates are wide.
  ///
  /// A CITY or TOWN is judged absolutely, because a city legitimately extends
  /// far beyond its centroid and the existence of a nearer neighbourhood says
  /// nothing about whether the city name is right.
  static bool _isPlausibleFor(Place place, double latitude, double longitude) {
    final registry = LocationRegistry.instance;
    final km = registry.distanceKmTo(place, latitude, longitude);
    if (km == null) return true;

    if (place.kind != PlaceKind.area) return km <= _maxCityNameDriftKm;

    final nearest = registry.nearest(latitude, longitude, maxKm: _maxCityNameDriftKm);
    final nearestKm =
        nearest == null ? null : registry.distanceKmTo(nearest, latitude, longitude);
    if (nearestKm == null) return km <= _maxAreaNameDriftKm;
    return km <= nearestKm + _areaTieToleranceKm;
  }

  /// Opens the OS app settings (used by the "blocked" failure copy).
  static Future<void> openSettings() => openAppSettings();
}
