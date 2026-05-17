import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/location_service.dart';

class LocationProvider extends ChangeNotifier {
  PermissionStatus _status = PermissionStatus.denied;
  bool _isLoading = false;
  String? _city;
  double? _latitude;
  double? _longitude;

  PermissionStatus get status => _status;
  bool get isLoading => _isLoading;
  bool get isGranted => _status.isGranted;
  bool get isPermanentlyDenied => _status.isPermanentlyDenied;
  String? get city => _city;
  double? get latitude => _latitude;
  double? get longitude => _longitude;

  static String _cityKey(String uid) => 'location_city_$uid';
  static String _latKey(String uid) => 'location_lat_$uid';
  static String _lngKey(String uid) => 'location_lng_$uid';
  static String _explainerShownKey(String uid) => 'location_explainer_shown_$uid';

  Future<void> initializeForUser(String uid) async {
    _status = await LocationService.permissionStatus();
    if (uid.isEmpty) {
      _city = null;
      _latitude = null;
      _longitude = null;
      notifyListeners();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    _city = prefs.getString(_cityKey(uid));
    _latitude = prefs.getDouble(_latKey(uid));
    _longitude = prefs.getDouble(_lngKey(uid));
    notifyListeners();
  }

  Future<bool> shouldShowExplainer(String uid) async {
    if (uid.isEmpty) return false;
    _status = await LocationService.permissionStatus();
    if (_status.isGranted) return false;
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_explainerShownKey(uid)) ?? false);
  }

  Future<void> markExplainerShown(String uid) async {
    if (uid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_explainerShownKey(uid), true);
  }

  Future<bool> requestFromExplainer(String uid) async {
    if (_isLoading) return false;
    _isLoading = true;
    notifyListeners();
    try {
      await markExplainerShown(uid);
      final granted = await LocationService.requestPermission();
      _status = await LocationService.permissionStatus();
      if (!granted) return false;
      return await captureAndStoreCurrentLocation(uid);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> captureAndStoreCurrentLocation(String uid) async {
    final pos = await LocationService.getCurrentPosition(requestIfNeeded: false);
    if (pos == null || uid.isEmpty) return false;
    final resolvedCity = await LocationService.getCityFromCoordinates(
      latitude: pos.latitude,
      longitude: pos.longitude,
    );
    final prefs = await SharedPreferences.getInstance();
    _latitude = pos.latitude;
    _longitude = pos.longitude;
    _city = resolvedCity;
    await prefs.setDouble(_latKey(uid), pos.latitude);
    await prefs.setDouble(_lngKey(uid), pos.longitude);
    if (resolvedCity != null && resolvedCity.isNotEmpty) {
      await prefs.setString(_cityKey(uid), resolvedCity);
    }
    notifyListeners();
    return true;
  }

  Future<void> refreshPermissionStatus() async {
    _status = await LocationService.permissionStatus();
    notifyListeners();
  }

  Future<void> openSettingsAndRefresh() async {
    await openAppSettings();
    await refreshPermissionStatus();
  }
}
