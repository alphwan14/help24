import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
// permission_handler also exports a `ServiceStatus`; we want geolocator's here.
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;

/// A reverse-geocoded coordinate, split into the parts the product uses.
///
/// WHY THE WHOLE HIERARCHY IS KEPT
/// -------------------------------
/// The previous version kept `area` and `city` and threw the rest away — it
/// computed `county` and no caller ever read it, and it never looked at
/// `subAdministrativeArea` at all. In Kenya that field is usually the
/// **sub-county / constituency**, which is the level people actually name
/// ("Kisauni", "Westlands", "Likoni"). Dropping it while keeping `subLocality`
/// is how a phone standing in Kisauni came back labelled Nyali: `subLocality`
/// is a coarse, sparsely-mapped polygon on the Kenyan coast, and the more
/// precise answer was already in the response, unread.
///
/// Nothing here is used for distance. Distance is always latitude/longitude —
/// see `utils/proximity.dart` and the ranking engine's `distance` signal. These
/// are names, for display and for filters.
@immutable
class ReverseGeocodeResult {
  /// Neighbourhood / sub-locality ("Nyali", "Westlands"). Often null upcountry,
  /// and coarse on the coast.
  final String? area;

  /// City or town ("Mombasa", "Naivasha"). Always present.
  final String city;

  /// County — Kenya's first-level division ("Mombasa", "Nairobi"). The " County"
  /// suffix is stripped so it speaks the registry's vocabulary.
  final String? county;

  /// Sub-county / constituency ("Kisauni", "Changamwe"). The most reliably
  /// specific administrative name Android returns in Kenya.
  final String? subCounty;

  /// Ward, where the platform exposes one. Best effort and frequently null —
  /// Android's Kenyan dataset rarely goes below constituency.
  final String? ward;

  /// The town/city the platform reported, unmodified. [city] may have fallen
  /// back to a broader field; this one did not.
  final String? locality;

  /// The full address line, as the platform would print it.
  final String? formattedAddress;

  const ReverseGeocodeResult({
    this.area,
    required this.city,
    this.county,
    this.subCounty,
    this.ward,
    this.locality,
    this.formattedAddress,
  });

  /// How a person would say it: "Nyali, Mombasa" — or just "Naivasha" when the
  /// geocoder gave no neighbourhood, or when it echoed the city back as one.
  String get label {
    final a = area?.trim();
    if (a == null || a.isEmpty || a.toLowerCase() == city.toLowerCase()) return city;
    return '$a, $city';
  }

  /// Every name this coordinate has, most specific first.
  ///
  /// Callers walk this list rather than trusting one field, because which field
  /// carries the useful answer varies by region — on the coast it is
  /// [subCounty], in Nairobi it is [area], upcountry it is [locality].
  List<String> get namesBySpecificity => [
        for (final n in [ward, area, subCounty, locality, city, county])
          if (n != null && n.trim().isNotEmpty) n.trim(),
      ];
}

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

  // ── The precise fix ────────────────────────────────────────────────────────

  /// Stop waiting as soon as a fix is at least this good. 50 m is well inside a
  /// Kenyan neighbourhood, so it can never name the wrong one.
  static const double desiredAccuracyM = 50;

  /// The worst fix that may still be STORED as "where the user is". Beyond this
  /// the coordinate is a guess, and a guess that gets written into a post's
  /// latitude/longitude poisons every distance the ranking engine computes from
  /// it. Better to say "we couldn't place you" and let them pick a town.
  static const double acceptableAccuracyM = 150;

  /// How long to keep improving before settling for the best fix so far.
  static const Duration preciseFixTimeout = Duration(seconds: 12);

  /// A fix older than this is somewhere the user WAS.
  ///
  /// Android's fused provider answers a location request by immediately
  /// replaying its last cached fix, which can be hours old and kilometres away.
  /// Accepting the first callback is what let yesterday's position be stored as
  /// today's, and it is indistinguishable from a genuine fix unless you look at
  /// the timestamp — which nothing did.
  static const Duration maxFixAge = Duration(seconds: 45);

  /// The highest practical accuracy fix, or null when one cannot be obtained.
  ///
  /// WHY THIS EXISTS AND `getCurrentPosition` WAS NOT ENOUGH
  /// ------------------------------------------------------
  /// `Geolocator.getCurrentPosition` returns the FIRST location the platform
  /// offers. On Android that is routinely a cached or network-derived fix with
  /// an accuracy radius of one to three kilometres — a circle that comfortably
  /// spans several Mombasa neighbourhoods. Nothing in the app ever looked at
  /// `Position.accuracy` or `Position.timestamp`, so a 2 km guess and a 5 m
  /// satellite fix were treated identically, and whichever arrived first won.
  ///
  /// This listens instead of asking: it keeps the best fix seen, discards fixes
  /// that are stale or mocked, returns the moment [desiredAccuracy] is reached,
  /// and after [timeout] settles for the best it has — but only if that is
  /// within [acceptableAccuracy]. Otherwise it reports failure, because a
  /// coordinate nobody should trust is worse than no coordinate: the ranking
  /// engine treats a missing viewer location as "distance not applicable" and
  /// ranks honestly on everything else, whereas a wrong one silently mis-ranks
  /// every post.
  ///
  /// Battery: the stream runs for at most [timeout] and is always cancelled —
  /// including on the early-success path. There is no continuous listener.
  static Future<Position?> getPreciseFix({
    bool requestIfNeeded = false,
    Duration timeout = preciseFixTimeout,
    double desiredAccuracy = desiredAccuracyM,
    double acceptableAccuracy = acceptableAccuracyM,
  }) async {
    final has = await hasPermission();
    if (!has) {
      if (!requestIfNeeded) return null;
      if (!await requestPermission()) return null;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      debugPrint('[LOCATION] precise fix aborted: device location is off');
      return null;
    }

    final completer = Completer<Position?>();
    Position? best;
    StreamSubscription<Position>? sub;
    Timer? deadline;

    void finish(Position? result) {
      if (completer.isCompleted) return;
      deadline?.cancel();
      sub?.cancel();
      completer.complete(result);
    }

    bool isUsable(Position p) {
      if (!p.latitude.isFinite || !p.longitude.isFinite) return false;
      if (p.isMocked) return false;
      final age = DateTime.now().difference(p.timestamp);
      // Negative ages happen when the device clock and the fix clock disagree;
      // treat only the clearly-old ones as stale.
      return age <= maxFixAge;
    }

    void consider(Position p) {
      if (!isUsable(p)) {
        debugPrint('[LOCATION] discarded fix (stale or mocked): '
            '±${p.accuracy.toStringAsFixed(0)} m, ${p.timestamp.toIso8601String()}');
        return;
      }
      if (best == null || p.accuracy < best!.accuracy) best = p;
      if (best!.accuracy <= desiredAccuracy) {
        debugPrint('[LOCATION] precise fix ±${best!.accuracy.toStringAsFixed(0)} m');
        finish(best);
      }
    }

    deadline = Timer(timeout, () {
      final settled = best;
      if (settled == null) {
        debugPrint('[LOCATION] no fix within ${timeout.inSeconds}s');
        finish(null);
      } else if (settled.accuracy <= acceptableAccuracy) {
        debugPrint('[LOCATION] settled for ±${settled.accuracy.toStringAsFixed(0)} m');
        finish(settled);
      } else {
        // The honest failure. See the doc comment: a coordinate this coarse
        // would be stored, posted and ranked on as though it were precise.
        debugPrint('[LOCATION] rejected best fix ±${settled.accuracy.toStringAsFixed(0)} m '
            '(worse than ${acceptableAccuracy.toStringAsFixed(0)} m)');
        finish(null);
      }
    });

    try {
      sub = Geolocator.getPositionStream(locationSettings: _preciseSettings()).listen(
        consider,
        onError: (Object e) {
          debugPrint('[LOCATION] precise fix stream error: $e');
          finish(best != null && best!.accuracy <= acceptableAccuracy ? best : null);
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[LOCATION] precise fix could not start: $e');
      finish(null);
    }

    return completer.future;
  }

  /// Settings for a short, high-accuracy burst.
  ///
  /// `LocationAccuracy.best` (not `high`) so Android asks the GNSS chip rather
  /// than settling for the fused provider's network estimate, and
  /// `distanceFilter: 0` so every improvement is delivered instead of being
  /// suppressed for not having moved far enough — improving accuracy while
  /// standing still is precisely what this is here to do.
  static LocationSettings _preciseSettings() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        forceLocationManager: false,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
    );
  }

  /// Reverse geocode coordinates to a best-effort city/locality.
  static Future<String?> getCityFromCoordinates({
    required double latitude,
    required double longitude,
  }) async {
    final resolved = await reverseGeocode(latitude: latitude, longitude: longitude);
    return resolved?.city;
  }

  /// Reverse geocode into its two useful PARTS rather than one string.
  ///
  /// The city alone is what the app used to keep, and it is not what a person
  /// says: nobody in Nyali tells you they are "in Mombasa" when arranging a
  /// job. The neighbourhood is the useful half and the city is the half that
  /// filters and matching need — so both are returned and the caller decides
  /// how to compose them.
  ///
  /// Null when the geocoder has no answer (it needs network on Android) — the
  /// caller then falls back to snapping the coordinate to the nearest known
  /// town, which works offline.
  static Future<ReverseGeocodeResult?> reverseGeocode({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final placemarks = await placemarkFromCoordinates(latitude, longitude)
          .timeout(const Duration(seconds: 10));
      if (placemarks.isEmpty) return null;

      // The MOST DESCRIBED placemark, not the first one. Android returns
      // several for one coordinate and orders them by its own relevance rules;
      // `.first` is frequently the one with a street and nothing else, while a
      // later entry carries the administrative hierarchy this needs.
      final p = placemarks.reduce(
          (a, b) => _placemarkDetail(b) > _placemarkDetail(a) ? b : a);

      final locality = _clean(p.locality);
      final subCounty = _clean(p.subAdministrativeArea);
      final county = _stripCountySuffix(_clean(p.administrativeArea));
      final area = _clean(p.subLocality);
      // Ward is not a field Android models. Where a name exists below
      // sub-locality it arrives as `thoroughfare`; treated as a best-effort
      // hint and never as a requirement.
      final ward = _clean(p.thoroughfare);

      final city = locality ?? subCounty ?? county;
      if (city == null && area == null) return null;

      return ReverseGeocodeResult(
        area: area,
        city: city ?? area!,
        county: county,
        subCounty: subCounty,
        ward: ward,
        locality: locality,
        formattedAddress: _formatAddress(p),
      );
    } catch (e) {
      debugPrint('LocationService reverseGeocode: $e');
      return null;
    }
  }

  static String? _clean(String? v) {
    final t = v?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// How much administrative detail a placemark carries — the tie-break for
  /// choosing among several answers to one coordinate.
  static int _placemarkDetail(Placemark p) {
    var score = 0;
    for (final field in [
      p.subLocality,
      p.locality,
      p.subAdministrativeArea,
      p.administrativeArea,
      p.thoroughfare,
      p.postalCode,
    ]) {
      if (_clean(field) != null) score++;
    }
    return score;
  }

  /// "Mombasa County" → "Mombasa".
  ///
  /// The registry stores bare county names and the city filter compares against
  /// them, so keeping the platform's suffix would mean a county that matches
  /// nothing — the same vocabulary drift that made the old city string useless.
  static String? _stripCountySuffix(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    final lower = trimmed.toLowerCase();
    if (lower.endsWith(' county')) {
      final stripped = trimmed.substring(0, trimmed.length - ' county'.length).trim();
      return stripped.isEmpty ? trimmed : stripped;
    }
    return trimmed;
  }

  /// The address as a person would write it, deduplicated.
  ///
  /// Android happily repeats the same name across `subLocality`, `locality` and
  /// `subAdministrativeArea`; printing all of them gives "Nyali, Nyali,
  /// Mombasa".
  static String? _formatAddress(Placemark p) {
    final parts = <String>[];
    for (final field in [
      p.street,
      p.subLocality,
      p.locality,
      p.subAdministrativeArea,
      p.administrativeArea,
      p.country,
    ]) {
      final value = _clean(field);
      if (value == null) continue;
      if (parts.any((existing) => existing.toLowerCase() == value.toLowerCase())) {
        continue;
      }
      parts.add(value);
    }
    return parts.isEmpty ? null : parts.join(', ');
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
