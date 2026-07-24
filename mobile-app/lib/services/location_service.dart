import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
// permission_handler also exports a `ServiceStatus`; we want geolocator's here.
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;

/// Handles device location: permission request and current position.
/// Use for "send current location" and as source for live location updates.
class LocationService {
  static Future<PermissionStatus> permissionStatus() {
    return Permission.locationWhenInUse.status;
  }

  /// Whether the DEVICE's location service (the OS toggle) is currently on.
  /// This is independent of app permission — turning off Android's Location
  /// quick-setting disables the service without revoking `locationWhenInUse`.
  static Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  /// Live stream of the device location service flipping on/off, mapped to a
  /// simple bool. Lets the app mirror the OS toggle in real time instead of
  /// discovering the change only on the next resume or location read.
  static Stream<bool> serviceEnabledStream() =>
      Geolocator.getServiceStatusStream().map((s) => s == ServiceStatus.enabled);

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
      // timeLimit ensures a device that never gets a fix throws
      // TimeoutException instead of leaving this Future (and its callers, e.g.
      // journey start and captureAndStoreCurrentLocation) pending forever.
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
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
      final placemarks = await placemarkFromCoordinates(latitude, longitude)
          .timeout(const Duration(seconds: 10));
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

  // Removed: positionUpdatesEvery(), a getCurrentPosition polling loop that
  // journeys used before Phase 2. Every caller now uses journeyPositionStream
  // and the old loop had no remaining references — leaving it invited a future
  // caller to reintroduce polling and the battery cost that came with it.

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
