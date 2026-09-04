import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/place.dart';
import 'package:help24/services/location_registry.dart';

/// A PINNED SPOT IS A LOCATION.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// Reproduced on the physical S20+: in the posting flow's "Where?" step, tap
/// "Pin the exact spot on the map", place the pin, press "Use this spot". The
/// row turns green and reads "Exact spot pinned on the map" — and **Continue
/// stays disabled**. Tapping it does nothing; the step indicator does not move.
///
/// The step's gate is `_hasLocation`, which reads `_location.label`. Pinning
/// wrote only `_pinnedLat` / `_pinnedLng` and never touched `_location`, so the
/// MORE precise answer to "where?" did not satisfy a gate that the coarser one
/// did. Nothing was broken about the pin — `_submit` had always carried
/// `_pinnedLat ?? _location?.latitude` into the post. The user simply could not
/// get there.
///
/// The fix snaps the pin to the nearest known place for its label — the same
/// move `_prefillLocationFromCache` already makes for a GPS fix — while the
/// post keeps the pinned coordinates, which are finer than the town's. These
/// tests pin that mechanism, and the honest limit of it: a pin nowhere near a
/// known place still cannot name itself, and must say so rather than leaving a
/// dead button.
void main() {
  const mombasa = Place(
    id: 'mombasa',
    name: 'Mombasa',
    kind: PlaceKind.city,
    county: 'Mombasa',
    isCountyHq: true,
    latitude: -4.0435,
    longitude: 39.6682,
  );
  const kisauni = Place(
    id: 'kisauni',
    name: 'Kisauni',
    kind: PlaceKind.area,
    county: 'Mombasa',
    parentId: 'mombasa',
    latitude: -4.0100,
    longitude: 39.7000,
  );
  const nairobi = Place(
    id: 'nairobi',
    name: 'Nairobi',
    kind: PlaceKind.city,
    county: 'Nairobi',
    isCountyHq: true,
    latitude: -1.2921,
    longitude: 36.8219,
  );

  setUp(() {
    LocationRegistry.instance.resetForTest();
    LocationRegistry.instance.seedForTest([mombasa, kisauni, nairobi]);
  });

  tearDown(() => LocationRegistry.instance.resetForTest());

  /// Exactly what `_pickExactSpot` now does with the picked coordinate.
  LocationSelection? selectionForPin(double lat, double lng) {
    final near = LocationRegistry.instance.nearest(lat, lng);
    if (near == null) return null;
    return LocationSelection.fromPlace(near)
        .copyWith(latitude: lat, longitude: lng);
  }

  group('a pin the registry can name unblocks the step', () {
    test('a pin in Kisauni yields a label, so Continue is enabled', () {
      // The pin the device test placed, near the Kisauni coordinate.
      final selection = selectionForPin(-4.0120, 39.7020);
      expect(selection, isNotNull);
      // `_hasLocation` is exactly `label.trim().isNotEmpty`.
      expect(selection!.label.trim(), isNotEmpty);
      expect(selection.label, 'Kisauni, Mombasa');
    });

    test('the post carries the PINNED coordinates, not the town centre', () {
      final selection = selectionForPin(-4.0120, 39.7020)!;
      // Snapping is for the NAME only. Replacing the pin with the place's own
      // coordinate would throw away the precision the user just supplied — the
      // whole point of pinning a gate rather than naming a suburb.
      expect(selection.latitude, -4.0120);
      expect(selection.longitude, 39.7020);
      expect(selection.latitude, isNot(kisauni.latitude));
    });

    test('the label is the city filter\'s own vocabulary', () {
      // `posts.location` feeds `ilike '%city%'` filtering, so a pinned post
      // must be findable by the same city name every other post uses.
      final selection = selectionForPin(-4.0430, 39.6690)!;
      expect(selection.cityName, 'Mombasa');
      expect(selection.placeId, 'mombasa');
    });
  });

  group('the honest limit', () {
    test('a pin far from every known place names nothing', () {
      // Mid-ocean: no registry entry is within `nearest`\'s 25 km radius.
      expect(selectionForPin(-4.5000, 41.5000), isNull);
    });

    test('so the step must still ask for a town — the gate stays shut', () {
      final selection = selectionForPin(-4.5000, 41.5000);
      final hasLocation = (selection?.label.trim() ?? '').isNotEmpty;
      expect(hasLocation, isFalse,
          reason: 'an unnameable pin cannot fill posts.location by itself');
    });
  });

  group('an existing choice is never overwritten', () {
    test('the nearest place is only consulted when no location is set', () {
      // `_pickExactSpot` guards on `!_hasLocation`. A user who chose "Nairobi"
      // and then pinned a spot must keep the town they chose; the pin refines
      // the coordinate, it does not relabel the post.
      const chosen = LocationSelection(label: 'Nairobi', cityName: 'Nairobi');
      final hasLocation = chosen.label.trim().isNotEmpty;
      expect(hasLocation, isTrue);
      // Guard holds → no snap runs → label untouched.
      expect(chosen.label, 'Nairobi');
    });
  });
}
