import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

/// Handles device location: permission request and current position.
/// Use for "send current location" and as source for live location updates.
class LocationService {
  static Future<PermissionStatus> permissionStatus() {
    return Permission.locationWhenInUse.status;
  }

  /// Request location permission. Returns true if granted or already granted.
  static Future<bool> requestPermission() async {
    final status = await Permission.locationWhenInUse.request();
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) return false;
    return false;
  }

  /// Check if we have permission (granted or while-in-use).
  static Future<bool> hasPermission() async {
    final status = await Permission.locationWhenInUse.status;
    return status.isGranted;
  }

  /// Get current position.
  /// If [requestIfNeeded] is true, requests permission when missing.
  static Future<Position?> getCurrentPosition({bool requestIfNeeded = true}) async {
    final has = await hasPermission();
    if (!has && requestIfNeeded) {
      final granted = await requestPermission();
      if (!granted) return null;
    } else if (!has) {
      return null;
    }
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('LocationService: location services disabled');
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
    } catch (e) {
      debugPrint('LocationService getCurrentPosition: $e');
      return null;
    }
  }

  /// Reverse geocode coordinates to a best-effort city/locality.
  static Future<String?> getCityFromCoordinates({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final placemarks = await placemarkFromCoordinates(latitude, longitude);
      if (placemarks.isEmpty) return null;
      final p = placemarks.first;
      final city = p.locality?.trim();
      if (city != null && city.isNotEmpty) return city;
      final subAdmin = p.subAdministrativeArea?.trim();
      if (subAdmin != null && subAdmin.isNotEmpty) return subAdmin;
      final admin = p.administrativeArea?.trim();
      if (admin != null && admin.isNotEmpty) return admin;
      return null;
    } catch (e) {
      debugPrint('LocationService getCityFromCoordinates: $e');
      return null;
    }
  }

  /// Stream of position updates at a fixed [intervalSeconds] (e.g. 8).
  /// Cancel the subscription when live sharing ends.
  ///
  /// Legacy polling loop — journeys now use [journeyPositionStream]. Kept for
  /// any non-journey callers; do not use for new work.
  static Stream<Position> positionUpdatesEvery({int intervalSeconds = 8}) async* {
    while (true) {
      final pos = await getCurrentPosition();
      if (pos != null) yield pos;
      await Future<void>.delayed(Duration(seconds: intervalSeconds));
    }
  }

  /// The journey pipeline's position source: a true platform stream (fused
  /// provider callbacks) instead of a getCurrentPosition polling loop — lower
  /// battery cost, immediate error propagation (GPS off → onError instead of
  /// silent nulls), and the only route to background updates.
  ///
  /// [foregroundService]: when true (journeys only), Android runs geolocator's
  /// own foreground service (`GeolocatorLocationService`, declared by the
  /// plugin with foregroundServiceType="location") with a persistent
  /// notification, so fixes keep flowing while the screen is locked or the app
  /// is backgrounded. The service stops automatically when the stream
  /// subscription is cancelled — journey end tears it down deterministically.
  static Stream<Position> journeyPositionStream({bool foregroundService = false}) {
    late final LocationSettings settings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 8),
        foregroundNotificationConfig: foregroundService
            ? const ForegroundNotificationConfig(
                notificationTitle: 'Sharing your journey',
                notificationText:
                    'Help24 is sharing your live location with this chat until you arrive or stop.',
                notificationIcon:
                    AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
                enableWakeLock: false,
                setOngoing: true,
              )
            : null,
      );
    } else {
      settings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      );
    }
    return Geolocator.getPositionStream(locationSettings: settings);
  }
}
