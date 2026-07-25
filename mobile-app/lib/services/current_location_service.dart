import 'package:flutter/foundation.dart';
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
    final pos = await LocationService.getCurrentPosition(requestIfNeeded: false);
    if (pos == null) {
      return const CurrentLocationResult.failed(CurrentLocationFailure.noFix);
    }

    final selection = await describe(pos.latitude, pos.longitude);
    if (selection == null) {
      return CurrentLocationResult.failed(
        CurrentLocationFailure.unnamed,
        latitude: pos.latitude,
        longitude: pos.longitude,
      );
    }
    return CurrentLocationResult.success(selection);
  }

  /// Names a coordinate the caller already has (a map pin, a stored fix).
  /// Same ladder as [resolve], without any permission or GPS work.
  static Future<LocationSelection?> describe(double latitude, double longitude) async {
    final registry = LocationRegistry.instance;
    await registry.ensureBundled();

    // Rung 1 — the geocoder.
    final geo = await LocationService.reverseGeocode(
      latitude: latitude,
      longitude: longitude,
    );
    if (geo != null) {
      // Reconcile against the vocabulary so GPS and the filters speak the same
      // language. Prefer the neighbourhood match, then the city match.
      final match = registry.resolveLabel(geo.label) ??
          registry.resolveLabel(geo.area) ??
          registry.resolveLabel(geo.city);
      if (match != null) {
        return LocationSelection(
          label: match.storageLabel,
          cityName: match.cityName,
          areaName: match.areaName,
          placeId: match.id,
          latitude: latitude,
          longitude: longitude,
          source: LocationSource.gps,
        );
      }
      // Geocoder named somewhere the registry has never heard of. That is a
      // real place and a perfectly good post location — keep the user's truth
      // rather than snapping them to a town they are not in.
      return LocationSelection(
        label: geo.label,
        cityName: geo.city,
        areaName: geo.area,
        latitude: latitude,
        longitude: longitude,
        source: LocationSource.gps,
      );
    }

    // Rung 2 — offline snap to the nearest known town.
    final near = registry.nearest(latitude, longitude);
    if (near != null) {
      debugPrint('[CURRENT_LOCATION] geocoder silent, snapped to ${near.id}');
      return LocationSelection(
        label: near.storageLabel,
        cityName: near.cityName,
        areaName: near.areaName,
        placeId: near.id,
        latitude: latitude,
        longitude: longitude,
        source: LocationSource.gpsSnapped,
      );
    }

    // Rung 3 — nothing could name it.
    return null;
  }

  /// Opens the OS app settings (used by the "blocked" failure copy).
  static Future<void> openSettings() => openAppSettings();
}
