import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/place.dart';
import '../services/current_location_service.dart';
import '../services/location_service.dart';
import '../utils/proximity.dart';

class LocationProvider extends ChangeNotifier {
  PermissionStatus _status = PermissionStatus.denied;
  bool _isLoading = false;
  String? _city;
  double? _latitude;
  double? _longitude;
  DateTime? _lastUpdated;

  /// The full location record — coordinates, accuracy, and the administrative
  /// hierarchy the fix resolved to. [_city] and the coordinate fields above are
  /// projections of this, kept as separate fields because a great many call
  /// sites read them directly.
  LocationSelection? _record;

  /// How long a stored position is treated as still describing where the user
  /// is.
  ///
  /// This threshold did not previously exist: `_lastUpdated` was written on
  /// every capture and read by nothing, so a position captured once was reused
  /// indefinitely. A user who enabled location in Nyali last month was still
  /// being ranked from Nyali today — which is the plainest possible reading of
  /// "Help24 stores Nyali", and no amount of GPS accuracy fixes it.
  ///
  /// Twenty minutes is a compromise between a marketplace where people move
  /// between jobs and a battery that has to last the day. Nothing polls: this
  /// is only ever consulted when something else already woke the app up.
  static const Duration freshnessWindow = Duration(minutes: 20);

  /// How far the user must have moved for the refresh to be worth telling
  /// anyone about. Matches the feed's own significance threshold, so a refresh
  /// that reports movement is always a refresh that could change the ranking.
  static const double significantMoveKm = 1.0;

  /// The DEVICE location service (OS toggle) on/off — tracked LIVE so the UI
  /// mirrors Android instantly when the user flips the quick-setting. Optimistic
  /// at construction; corrected within a frame by the seed read below.
  bool _serviceEnabled = true;
  StreamSubscription<bool>? _serviceSub;

  LocationProvider() {
    _watchServiceStatus();
  }

  void _watchServiceStatus() {
    // Seed the current state, then follow every OS toggle in real time.
    LocationService.isServiceEnabled().then((enabled) {
      if (_serviceEnabled != enabled) {
        _serviceEnabled = enabled;
        notifyListeners();
      }
    });
    _serviceSub = LocationService.serviceEnabledStream().listen((enabled) {
      if (_serviceEnabled != enabled) {
        _serviceEnabled = enabled;
        notifyListeners();
      }
    });
  }

  PermissionStatus get status => _status;
  bool get isLoading => _isLoading;
  bool get isGranted => _status.isGranted;
  bool get isPermanentlyDenied => _status.isPermanentlyDenied;

  /// Whether the device location service (OS toggle) is currently on.
  bool get serviceEnabled => _serviceEnabled;

  /// The OS CAPABILITY: the app has permission AND the device service is on, so
  /// a fix is obtainable. (Doesn't say the user is actually using location.)
  bool get isLocationActive => _status.isGranted && _serviceEnabled;

  /// What the Profile UI shows as "Enabled": location is obtainable AND the user
  /// has an active stored location. In-app "Disable Location" clears that stored
  /// location (without touching OS permission), so this flips to false the
  /// moment the user disables — which the OS-capability flags alone never did.
  bool get isLocationOn => isLocationActive && _latitude != null;
  String? get city => _city;
  double? get latitude => _latitude;
  double? get longitude => _longitude;
  DateTime? get lastUpdated => _lastUpdated;

  /// The full stored location, including its administrative hierarchy and the
  /// accuracy of the fix that produced it. Null when nothing is stored.
  LocationSelection? get record => _record;

  /// The radius, in metres, the stored position is accurate to.
  double? get accuracyMeters => _record?.accuracyMeters;

  /// County / sub-county (constituency) / ward, where each could be determined.
  String? get county => _record?.county;
  String? get subCounty => _record?.subCounty;
  String? get ward => _record?.ward;
  String? get formattedAddress => _record?.formattedAddress;

  /// Whether the stored position is old enough to be worth re-reading.
  ///
  /// "No stored position" is NOT stale — there is nothing to refresh, and
  /// treating it as stale would turn every app resume into a permission-free
  /// GPS attempt for users who never enabled location.
  bool get isStale {
    final at = _lastUpdated;
    if (at == null || _latitude == null) return false;
    return DateTime.now().difference(at) >= freshnessWindow;
  }

  static String _cityKey(String uid) => 'location_city_$uid';
  static String _latKey(String uid) => 'location_lat_$uid';
  static String _lngKey(String uid) => 'location_lng_$uid';
  static String _lastUpdatedKey(String uid) => 'location_last_updated_$uid';
  static String _explainerShownKey(String uid) => 'location_explainer_shown_$uid';

  /// The full record, as JSON. The four keys above are still written so that a
  /// downgrade — or any code still reading them — keeps working.
  static String _recordKey(String uid) => 'location_record_$uid';

  Future<void> initializeForUser(String uid) async {
    _status = await LocationService.permissionStatus();
    if (uid.isEmpty) {
      _clearInMemory();
      notifyListeners();
      return;
    }
    final prefs = await SharedPreferences.getInstance();

    // Prefer the full record; fall back to the legacy scalar keys so a user who
    // stored a location before this existed keeps it.
    final raw = prefs.getString(_recordKey(uid));
    if (raw != null) {
      try {
        _record = LocationSelection.fromJson(jsonDecode(raw));
      } catch (e) {
        debugPrint('[LOCATION] stored record unreadable, falling back: $e');
        _record = null;
      }
    }

    _latitude = _record?.latitude ?? prefs.getDouble(_latKey(uid));
    _longitude = _record?.longitude ?? prefs.getDouble(_lngKey(uid));
    _city = _record?.cityName ?? prefs.getString(_cityKey(uid));
    final ts = prefs.getString(_lastUpdatedKey(uid));
    _lastUpdated = ts != null ? DateTime.tryParse(ts) : null;
    notifyListeners();
  }

  void _clearInMemory() {
    _city = null;
    _latitude = null;
    _longitude = null;
    _lastUpdated = null;
    _record = null;
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

  /// Read the device's position at the highest practical accuracy and store it.
  ///
  /// Goes through [CurrentLocationService.resolve], which waits for a fix good
  /// enough to name a neighbourhood with and refuses to return a coarse or
  /// stale one. The value written here becomes the viewer coordinate the
  /// ranking engine measures every distance from, so accepting a kilometre-wide
  /// guess would mis-rank every post silently — a failure that looks exactly
  /// like a working feed.
  Future<bool> captureAndStoreCurrentLocation(String uid) async {
    if (uid.isEmpty) return false;
    final result = await CurrentLocationService.resolve(requestPermission: false);
    if (!result.isSuccess) {
      debugPrint('[LOCATION] capture failed: ${result.failure?.name}');
      return false;
    }
    await _store(uid, result.selection!);
    return true;
  }

  /// Refresh the stored position only if it has gone stale.
  ///
  /// Returns true when the position moved far enough to matter — which is the
  /// only case a caller needs to act on. A refresh that lands within
  /// [significantMoveKm] of where we already were returns false, so the feed is
  /// never rebuilt for a user who has been sitting in the same room.
  ///
  /// This is the whole of the "intelligent updates" policy: no timer, no
  /// position stream, no polling. It runs when the app resumes, does nothing at
  /// all unless [isStale], and costs one bounded GPS burst when it does.
  Future<bool> refreshIfStale(String uid) async {
    if (uid.isEmpty || !isStale || _isLoading) return false;
    if (!isLocationActive) return false;

    final previousLat = _latitude;
    final previousLng = _longitude;

    _isLoading = true;
    try {
      final ok = await captureAndStoreCurrentLocation(uid);
      if (!ok) return false;
      if (previousLat == null || previousLng == null) return true;
      final moved =
          distanceKm(previousLat, previousLng, _latitude!, _longitude!);
      debugPrint('[LOCATION] refreshed, moved ${moved.toStringAsFixed(2)} km');
      return moved >= significantMoveKm;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Persist [selection] as the user's location, in full.
  ///
  /// `_city` is consumed as a CITY NAME — it seeds the posting form and the city
  /// filter, which matches it against `posts.location` as a substring — so what
  /// is written is the registry-reconciled name, never the geocoder's raw
  /// string. The rest of the hierarchy rides along in the record so that a
  /// location can later be explained rather than guessed at.
  Future<void> _store(String uid, LocationSelection selection) async {
    final now = DateTime.now();
    final prefs = await SharedPreferences.getInstance();

    _record = selection;
    _latitude = selection.latitude;
    _longitude = selection.longitude;
    _city = selection.cityName;
    _lastUpdated = now;

    await prefs.setString(_recordKey(uid), jsonEncode(selection.toJson()));
    if (selection.latitude != null) {
      await prefs.setDouble(_latKey(uid), selection.latitude!);
    }
    if (selection.longitude != null) {
      await prefs.setDouble(_lngKey(uid), selection.longitude!);
    }
    await prefs.setString(_lastUpdatedKey(uid), now.toIso8601String());
    if (selection.cityName.isNotEmpty) {
      await prefs.setString(_cityKey(uid), selection.cityName);
    }
    debugPrint('[LOCATION] stored "${selection.label}" '
        '(${selection.subCounty ?? '—'}, ${selection.county ?? '—'}) '
        '±${selection.accuracyMeters?.toStringAsFixed(0) ?? '?'} m');
    notifyListeners();
  }

  /// Clears cached location data without revoking OS permission.
  /// Use from the location settings sheet when user wants to disable in-app location.
  Future<void> disableLocation(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cityKey(uid));
    await prefs.remove(_latKey(uid));
    await prefs.remove(_lngKey(uid));
    await prefs.remove(_lastUpdatedKey(uid));
    await prefs.remove(_recordKey(uid));
    // Reset the explainer flag so it will be offered again if they re-enable.
    await prefs.remove(_explainerShownKey(uid));
    _clearInMemory();
    notifyListeners();
  }

  Future<void> refreshPermissionStatus() async {
    _status = await LocationService.permissionStatus();
    notifyListeners();
  }

  Future<void> openSettingsAndRefresh() async {
    await openAppSettings();
    await refreshPermissionStatus();
  }

  @override
  void dispose() {
    _serviceSub?.cancel();
    super.dispose();
  }
}
