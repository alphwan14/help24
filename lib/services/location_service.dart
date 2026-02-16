import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

/// Handles device location: permission request and current position.
/// Use for "send current location" and as source for live location updates.
class LocationService {
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

  /// Get current position. Requests permission if needed. Returns null if denied or error.
  static Future<Position?> getCurrentPosition() async {
    final has = await hasPermission();
    if (!has) {
      final granted = await requestPermission();
      if (!granted) return null;
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

  /// Stream of position updates at a fixed [intervalSeconds] (e.g. 8).
  /// Cancel the subscription when live sharing ends.
  static Stream<Position> positionUpdatesEvery({int intervalSeconds = 8}) async* {
    while (true) {
      final pos = await getCurrentPosition();
      if (pos != null) yield pos;
      await Future<void>.delayed(Duration(seconds: intervalSeconds));
    }
  }
}
