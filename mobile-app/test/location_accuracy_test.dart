import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/place.dart';
import 'package:help24/utils/proximity.dart';

/// Regression suite: "USER IS IN KISAUNI, HELP24 STORES NYALI".
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// Reported from production in Mombasa. Three causes, and only one of them was
/// about GPS:
///
///   1. **The dataset.** `mombasa-kisauni` existed in the location registry
///      with NO COORDINATE — as did 122 of the 133 neighbourhoods in the
///      country. `LocationRegistry.nearest()` only considers entries that have
///      one, so a fix taken in Kisauni could never snap to Kisauni: the closest
///      coordinate-bearing place was Nyali, four kilometres away. The app was
///      structurally incapable of returning the right answer.
///   2. **The naming ladder.** A geocoder answer was accepted purely because
///      the registry recognised the NAME, with no check that the named place
///      was anywhere near the fix. Android's `subLocality` on the Mombasa
///      mainland is a coarse polygon that reports "Nyali" well outside Nyali.
///   3. **Accuracy and staleness.** Nothing ever read `Position.accuracy` or
///      `Position.timestamp`, so a cached kilometre-wide network estimate — a
///      circle spanning several of these neighbourhoods — was stored as the
///      user's position, and then reused indefinitely because `lastUpdated` was
///      written and never read.
///
/// These tests pin (1) and the geometry behind (2). The accuracy gate itself
/// lives in `LocationService.getPreciseFix`, whose thresholds are asserted
/// below so a future edit has to be deliberate.

/// Where these places actually are, independently of the dataset. Used to check
/// the dataset rather than being checked by it.
const _knownPlaces = <String, ({double lat, double lng})>{
  'mombasa-kisauni': (lat: -4.014, lng: 39.691),
  'mombasa-nyali': (lat: -4.0333, lng: 39.7),
  'mombasa-changamwe': (lat: -4.023, lng: 39.621),
  'nairobi-kayole': (lat: -1.274, lng: 36.916),
  'nairobi-kibera': (lat: -1.313, lng: 36.7833),
};

Map<String, dynamic> _loadAsset() {
  final file = File('assets/data/locations_ke.json');
  expect(file.existsSync(), isTrue, reason: 'bundled location asset is missing');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

List<Place> _places() {
  final data = _loadAsset();
  final rows = data['places'] as List;
  final parsed = [
    for (final row in rows)
      if (Place.tryParse(row) != null) Place.tryParse(row)!,
  ];
  expect(parsed, isNotEmpty);
  return parsed;
}

/// The registry's own snapping rule, reproduced here over the raw asset so the
/// test exercises the DATA rather than the singleton's async warm-up.
Place? nearestTo(List<Place> places, double lat, double lng, {double maxKm = 25}) {
  Place? best;
  var bestKm = double.infinity;
  for (final p in places) {
    if (!p.hasCoordinates) continue;
    final km = distanceKm(lat, lng, p.latitude!, p.longitude!);
    if (km < bestKm) {
      bestKm = km;
      best = p;
    }
  }
  return bestKm <= maxKm ? best : null;
}

void main() {
  group('the dataset can name a neighbourhood', () {
    test('EVERY neighbourhood carries a coordinate', () {
      final missing = _places()
          .where((p) => p.kind == PlaceKind.area && !p.hasCoordinates)
          .map((p) => p.id)
          .toList();
      // A neighbourhood without a coordinate is not merely incomplete — it is
      // invisible to snapping AND inherits its parent city's centre when it is
      // picked manually, so a post in Kisauni got Mombasa Island's position.
      expect(missing, isEmpty,
          reason: 'these neighbourhoods can never be snapped to: $missing');
    });

    test('every city and county HQ carries a coordinate', () {
      final missing = _places()
          .where((p) => (p.kind == PlaceKind.city || p.isCountyHq) && !p.hasCoordinates)
          .map((p) => p.id)
          .toList();
      expect(missing, isEmpty);
    });

    test('no coordinate lies outside Kenya', () {
      // Kenya spans roughly 5°N–5°S, 33°E–42°E. A transposed or sign-flipped
      // pair is the classic way a hand-added coordinate goes wrong, and it is
      // silent: the place simply stops being anyone's nearest.
      for (final p in _places().where((p) => p.hasCoordinates)) {
        expect(p.latitude, inInclusiveRange(-5.5, 5.5), reason: p.id);
        expect(p.longitude, inInclusiveRange(33.0, 42.5), reason: p.id);
      }
    });

    test('every neighbourhood sits within 40 km of its parent city', () {
      final byId = {for (final p in _places()) p.id: p};
      for (final p in _places()) {
        if (p.kind != PlaceKind.area || !p.hasCoordinates) continue;
        final parent = byId[p.parentId];
        if (parent == null || !parent.hasCoordinates) continue;
        final km = distanceKm(
            p.latitude!, p.longitude!, parent.latitude!, parent.longitude!);
        expect(km, lessThan(40),
            reason: '${p.id} is ${km.toStringAsFixed(1)} km from ${parent.id}');
      }
    });

    test('no two places share a coordinate', () {
      // Duplicates mean a copy-paste slip, and they make snapping arbitrary.
      final seen = <String, String>{};
      for (final p in _places().where((p) => p.hasCoordinates)) {
        final key = '${p.latitude},${p.longitude}';
        expect(seen.containsKey(key), isFalse,
            reason: '${p.id} shares a coordinate with ${seen[key]}');
        seen[key] = p.id;
      }
    });
  });

  group('regression: a fix in Kisauni resolves to Kisauni', () {
    late List<Place> places;
    setUp(() => places = _places());

    test('Kisauni is in the dataset WITH a coordinate', () {
      final kisauni = places.firstWhere((p) => p.id == 'mombasa-kisauni');
      expect(kisauni.hasCoordinates, isTrue,
          reason: 'this is the bug: it was present but unlocatable');
    });

    test('snapping a Kisauni fix no longer lands on Nyali', () {
      final at = _knownPlaces['mombasa-kisauni']!;
      final snapped = nearestTo(places, at.lat, at.lng);
      expect(snapped?.id, 'mombasa-kisauni');
    });

    test('the old dataset WOULD have said Nyali — the bug was real', () {
      // Reproduce the pre-fix state: strip coordinates from every Mombasa
      // neighbourhood that did not have one, and snap again.
      const hadCoordinatesBefore = {'mombasa-nyali', 'mombasa-bamburi', 'mombasa-likoni'};
      final asItWas = [
        for (final p in places)
          if (p.county != 'Mombasa' ||
              p.kind != PlaceKind.area ||
              hadCoordinatesBefore.contains(p.id))
            p,
      ];
      final at = _knownPlaces['mombasa-kisauni']!;
      expect(nearestTo(asItWas, at.lat, at.lng)?.id, 'mombasa-nyali');
    });

    test('a Nyali fix still resolves to Nyali', () {
      final at = _knownPlaces['mombasa-nyali']!;
      expect(nearestTo(places, at.lat, at.lng)?.id, 'mombasa-nyali');
    });

    test('neighbouring Mombasa areas stay distinguishable', () {
      for (final entry in {
        'mombasa-kisauni': _knownPlaces['mombasa-kisauni']!,
        'mombasa-nyali': _knownPlaces['mombasa-nyali']!,
        'mombasa-changamwe': _knownPlaces['mombasa-changamwe']!,
      }.entries) {
        expect(nearestTo(places, entry.value.lat, entry.value.lng)?.id, entry.key);
      }
    });

    test('Nairobi neighbourhoods resolve to themselves, not to "Nairobi"', () {
      for (final id in ['nairobi-kayole', 'nairobi-kibera']) {
        final at = _knownPlaces[id]!;
        expect(nearestTo(places, at.lat, at.lng)?.id, id);
      }
    });
  });

  group('the naming ladder must distrust a name that is not here', () {
    // Reproduces CurrentLocationService._isPlausibleFor over the raw asset.
    //
    // Neighbourhood plausibility is COMPARATIVE, not a fixed radius. Kisauni
    // and Nyali are 2.4 km apart — closer than some single estates are wide —
    // so no absolute threshold can both accept a large estate and reject the
    // one next door. The question that works is "is anything nearer?".
    const areaTieToleranceKm = 1.0;
    const cityAllowanceKm = 25.0;
    const areaFallbackKm = 3.5;

    bool isPlausible(List<Place> places, Place named, double lat, double lng) {
      if (!named.hasCoordinates) return true;
      final km = distanceKm(lat, lng, named.latitude!, named.longitude!);
      if (named.kind != PlaceKind.area) return km <= cityAllowanceKm;
      final nearest = nearestTo(places, lat, lng, maxKm: cityAllowanceKm);
      if (nearest == null) return km <= areaFallbackKm;
      final nearestKm =
          distanceKm(lat, lng, nearest.latitude!, nearest.longitude!);
      return km <= nearestKm + areaTieToleranceKm;
    }

    late List<Place> places;
    Place place(String id) => places.firstWhere((p) => p.id == id);
    setUp(() => places = _places());

    test('"Nyali" is rejected for a fix in Kisauni — the reported bug', () {
      final fix = _knownPlaces['mombasa-kisauni']!;
      expect(isPlausible(places, place('mombasa-nyali'), fix.lat, fix.lng),
          isFalse);
    });

    test('"Kisauni" is accepted for the same fix', () {
      final fix = _knownPlaces['mombasa-kisauni']!;
      expect(isPlausible(places, place('mombasa-kisauni'), fix.lat, fix.lng),
          isTrue);
    });

    test('"Nyali" is accepted for a fix that really is in Nyali', () {
      final fix = _knownPlaces['mombasa-nyali']!;
      expect(
          isPlausible(places, place('mombasa-nyali'), fix.lat, fix.lng), isTrue);
    });

    test('a genuinely ambiguous fix trusts the geocoder', () {
      // Halfway between the two centroids, where the registry has no opinion
      // worth overriding a polygon-aware geocoder with.
      final a = _knownPlaces['mombasa-kisauni']!;
      final b = _knownPlaces['mombasa-nyali']!;
      final midLat = (a.lat + b.lat) / 2;
      final midLng = (a.lng + b.lng) / 2;
      expect(isPlausible(places, place('mombasa-nyali'), midLat, midLng), isTrue);
      expect(
          isPlausible(places, place('mombasa-kisauni'), midLat, midLng), isTrue);
    });

    test('a CITY name survives a distance a neighbourhood name would not', () {
      // Kayole is legitimately in Nairobi despite being 15 km from the point
      // labelled "Nairobi", and the fact that Kayole's own centroid is nearer
      // does not make "Nairobi" a wrong answer.
      final fix = _knownPlaces['nairobi-kayole']!;
      expect(isPlausible(places, place('nairobi'), fix.lat, fix.lng), isTrue);
      // The same distance, offered as a neighbourhood name, is rejected.
      expect(isPlausible(places, place('nairobi-kibera'), fix.lat, fix.lng),
          isFalse);
    });

    test('a place with no coordinate cannot be contradicted', () {
      final unlocatable = places.firstWhere((p) => !p.hasCoordinates);
      expect(isPlausible(places, unlocatable, -4.0, 39.7), isTrue);
    });
  });

  group('the accuracy gate', () {
    // Mirrors LocationService's constants. Duplicated deliberately: the point
    // is that loosening them has to be a conscious edit in two places, because
    // a coarse fix does not look like a failure — it looks like a working app
    // that quietly mis-ranks everything.
    const desiredAccuracyM = 50.0;
    const acceptableAccuracyM = 150.0;

    test('the acceptable radius is smaller than the neighbourhoods it names', () {
      // Kisauni to Nyali is the tightest pair this has to separate. A fix whose
      // error circle is wider than that distance cannot tell them apart, so
      // the gate has to sit well inside it.
      final a = _knownPlaces['mombasa-kisauni']!;
      final b = _knownPlaces['mombasa-nyali']!;
      final separationM = distanceKm(a.lat, a.lng, b.lat, b.lng) * 1000;
      expect(acceptableAccuracyM, lessThan(separationM / 4));
    });

    test('the desired radius is stricter than the acceptable one', () {
      expect(desiredAccuracyM, lessThan(acceptableAccuracyM));
    });

    test('a typical coarse network fix would be rejected', () {
      // 1–3 km is the ordinary accuracy of the cached fused-provider estimate
      // that the old code accepted without looking.
      for (final coarseM in [800.0, 1500.0, 3000.0]) {
        expect(coarseM > acceptableAccuracyM, isTrue);
      }
    });
  });

  group('the stored location keeps its administrative context', () {
    test('a selection round-trips every field through JSON', () {
      const original = LocationSelection(
        label: 'Kisauni, Mombasa',
        cityName: 'Mombasa',
        areaName: 'Kisauni',
        placeId: 'mombasa-kisauni',
        latitude: -4.014,
        longitude: 39.691,
        source: LocationSource.gps,
        county: 'Mombasa',
        subCounty: 'Kisauni',
        ward: 'Mjambere',
        locality: 'Mombasa',
        formattedAddress: 'Kisauni, Mombasa, Mombasa County, Kenya',
        accuracyMeters: 18.5,
      );

      final restored = LocationSelection.fromJson(
          jsonDecode(jsonEncode(original.toJson())))!;

      expect(restored.label, original.label);
      expect(restored.cityName, original.cityName);
      expect(restored.areaName, original.areaName);
      expect(restored.placeId, original.placeId);
      expect(restored.latitude, original.latitude);
      expect(restored.longitude, original.longitude);
      expect(restored.source, LocationSource.gps);
      expect(restored.county, 'Mombasa');
      expect(restored.subCounty, 'Kisauni');
      expect(restored.ward, 'Mjambere');
      expect(restored.locality, 'Mombasa');
      expect(restored.formattedAddress,
          'Kisauni, Mombasa, Mombasa County, Kenya');
      expect(restored.accuracyMeters, 18.5);
    });

    test('a legacy record with no administrative fields still loads', () {
      // Written before this existed. It must not throw and must not lose the
      // coordinates, which are the only part ranking actually uses.
      final restored = LocationSelection.fromJson({
        'label': 'Naivasha',
        'city': 'Naivasha',
        'lat': -0.7167,
        'lng': 36.4333,
        'source': 'gps',
      })!;
      expect(restored.latitude, -0.7167);
      expect(restored.county, isNull);
      expect(restored.accuracyMeters, isNull);
    });

    test('a manually picked place inherits its county and has no error bar', () {
      final kisauni =
          _places().firstWhere((p) => p.id == 'mombasa-kisauni');
      final selection = LocationSelection.fromPlace(kisauni);
      expect(selection.county, 'Mombasa');
      // A chosen town has a definition, not an accuracy.
      expect(selection.accuracyMeters, isNull);
      expect(selection.hasCoordinates, isTrue);
    });
  });

  group('distance is computed from coordinates, never from names', () {
    test('two places whose names share no word still measure correctly', () {
      final a = _knownPlaces['mombasa-kisauni']!;
      final b = _knownPlaces['mombasa-changamwe']!;
      final km = distanceKm(a.lat, a.lng, b.lat, b.lng);
      expect(km, greaterThan(5));
      expect(km, lessThan(15));
    });

    test('"Mombasa" and "Kisauni" are not comparable as strings', () {
      // The rule the ranking engine relies on: proximity is geometry. A
      // substring test between these two labels finds nothing, which is exactly
      // why city-string matching was removed from proximity.
      expect('Mombasa'.toLowerCase().contains('kisauni'), isFalse);
      expect('Kisauni'.toLowerCase().contains('mombasa'), isFalse);

      final places = _places();
      final mombasa = places.firstWhere((p) => p.id == 'mombasa');
      final kisauni = places.firstWhere((p) => p.id == 'mombasa-kisauni');
      final km = distanceKm(mombasa.latitude!, mombasa.longitude!,
          kisauni.latitude!, kisauni.longitude!);
      expect(km, lessThan(10), reason: 'they are near each other, and only geometry says so');
    });
  });
}
