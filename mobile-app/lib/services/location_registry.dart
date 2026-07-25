import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/place.dart';
import 'reference_registry.dart';

/// One row of the browse list: either a section letter or a place.
/// Precomputed once per dataset so the picker's ListView.builder does zero
/// work per row beyond reading a field.
@immutable
class PlaceRow {
  final String? header;
  final Place? place;
  const PlaceRow.header(String letter)
      : header = letter,
        place = null;
  const PlaceRow.place(Place value)
      : header = null,
        place = value;

  bool get isHeader => header != null;
}

/// The location vocabulary: every Kenyan city, county headquarters, major town
/// and — for the big urban centres — neighbourhood.
///
/// Source of truth is the server `locations` table (migration 088). The app
/// ships the same dataset as a bundled JSON asset, so the picker is complete
/// and searchable on a fresh install with no network, before any migration is
/// applied. See [ReferenceRegistry] for the full resolution order.
///
/// Everything a widget needs is SYNCHRONOUS. [warmUp] is fire-and-forget; a
/// location picker must open instantly and never spin.
class LocationRegistry extends ReferenceRegistry {
  LocationRegistry._();
  static final LocationRegistry instance = LocationRegistry._();

  /// Active country. The seam for the next market: point this at 'UG', ship
  /// `assets/data/locations_ug.json`, insert rows with country_code='UG'. No
  /// other Dart changes.
  String countryCode = 'KE';

  @override
  String get debugName => 'locations_${countryCode.toLowerCase()}';

  @override
  String get assetPath => 'assets/data/locations_${countryCode.toLowerCase()}.json';

  int _version = 0;
  @override
  int get loadedVersion => _version;

  List<Place> _places = const [];
  Map<String, Place> _byId = const {};
  Map<String, Place> _byLabel = const {};
  List<Place> _standalone = const [];
  List<Place> _geolocatable = const [];
  List<PlaceRow>? _browseRows;
  SearchIndex<Place>? _index;

  /// Every place, alphabetical by name.
  List<Place> get all => _places;

  /// Standalone locations only (cities + towns, no neighbourhoods) — the right
  /// list for a "which city?" filter.
  List<Place> get cities => _standalone;

  /// City/town NAMES, alphabetical. Kept for the legacy `KenyaLocation.cities`
  /// call sites so nothing had to change at once.
  List<String> get cityNames => _standalone.map((p) => p.name).toList();

  Place? byId(String? id) => id == null ? null : _byId[id];

  /// Neighbourhoods of a city, alphabetical. Empty for towns that have none —
  /// which, unlike the old hardcoded list, is now allowed to mean "this town
  /// genuinely has no sub-areas" instead of inventing a "Town Centre".
  List<Place> areasOf(String cityNameOrId) {
    final parent = _byId[cityNameOrId] ?? _lookupByName(cityNameOrId);
    if (parent == null) return const [];
    return _places
        .where((p) => p.kind == PlaceKind.area && p.parentId == parent.id)
        .toList();
  }

  Place? _lookupByName(String name) {
    final key = normalizeForSearch(name);
    if (key.isEmpty) return null;
    for (final p in _standalone) {
      if (normalizeForSearch(p.name) == key) return p;
    }
    return null;
  }

  /// Resolves a STORED location string back to a registry entry.
  ///
  /// Handles every shape `posts.location` has ever contained: "Westlands,
  /// Nairobi", "Nairobi", "nairobi", and legacy rows like "Town Centre, Voi"
  /// (the fake area the old list generated — the city half still resolves).
  /// Returns null for free text that matches nothing, which callers must treat
  /// as "display it verbatim", never as "no location".
  Place? resolveLabel(String? stored) {
    final raw = stored?.trim();
    if (raw == null || raw.isEmpty) return null;
    final exact = _byLabel[normalizeForSearch(raw)];
    if (exact != null) return exact;
    // "Something, City" → fall back to the city half.
    final comma = raw.lastIndexOf(',');
    if (comma > 0 && comma < raw.length - 1) {
      final city = raw.substring(comma + 1).trim();
      final hit = _lookupByName(city);
      if (hit != null) return hit;
    }
    return _lookupByName(raw);
  }

  /// Builds the postable selection for a place, filling in a coordinate from
  /// the parent city when the neighbourhood itself has none.
  ///
  /// Only a subset of entries carry a trustworthy coordinate (see the dataset:
  /// coordinates are never invented). A neighbourhood without one still needs
  /// *a* position for coarse distance sorting, and its city centre is both
  /// honest and good enough — unlike attaching wherever the poster's phone
  /// happened to be, which is what the app used to do and which produced posts
  /// whose coordinates contradicted their own label.
  LocationSelection selectionFor(Place place) {
    var lat = place.latitude;
    var lng = place.longitude;
    if (lat == null || lng == null) {
      final parent = _byId[place.parentId];
      lat = parent?.latitude;
      lng = parent?.longitude;
    }
    return LocationSelection(
      label: place.storageLabel,
      cityName: place.cityName,
      areaName: place.areaName,
      placeId: place.id,
      latitude: lat,
      longitude: lng,
    );
  }

  /// Ranked search. Safe to call on every keystroke — see [SearchIndex].
  List<Place> search(String query, {int limit = 60}) =>
      _index?.search(query, limit: limit) ?? const [];

  /// Alphabetical browse list with A–Z section headers. Built once.
  List<PlaceRow> get browseRows {
    final cached = _browseRows;
    if (cached != null) return cached;
    final rows = <PlaceRow>[];
    String? letter;
    for (final p in _places) {
      final l = p.sectionLetter;
      if (l != letter) {
        letter = l;
        rows.add(PlaceRow.header(l));
      }
      rows.add(PlaceRow.place(p));
    }
    return _browseRows = rows;
  }

  /// The known place closest to a coordinate, within [maxKm].
  ///
  /// This is what makes "Use current location" work with NO network: the
  /// platform geocoder needs data, but snapping a GPS fix to the nearest town
  /// in a bundled dataset does not. Only entries with a real coordinate are
  /// candidates — a neighbourhood without one can never be guessed at.
  Place? nearest(double latitude, double longitude, {double maxKm = 25}) {
    Place? best;
    var bestKm = double.infinity;
    for (final p in _geolocatable) {
      final km = _haversineKm(latitude, longitude, p.latitude!, p.longitude!);
      if (km < bestKm) {
        bestKm = km;
        best = p;
      }
    }
    return bestKm <= maxKm ? best : null;
  }

  /// Distance in km between a coordinate and a place, or null when the place
  /// has no coordinate. Used to sort "near me" results.
  double? distanceKmTo(Place place, double latitude, double longitude) {
    if (!place.hasCoordinates) return null;
    return _haversineKm(latitude, longitude, place.latitude!, place.longitude!);
  }

  /// The [limit] closest known places to a coordinate, nearest first.
  List<Place> nearbyPlaces(double latitude, double longitude, {int limit = 6, double maxKm = 60}) {
    final scored = <MapEntry<Place, double>>[];
    for (final p in _geolocatable) {
      final km = _haversineKm(latitude, longitude, p.latitude!, p.longitude!);
      if (km <= maxKm) scored.add(MapEntry(p, km));
    }
    scored.sort((a, b) => a.value.compareTo(b.value));
    return scored.take(limit).map((e) => e.key).toList();
  }

  @override
  bool applyPayload(Map<String, dynamic> payload) {
    final version = payload['version'];
    if (version is! int || version < _version) return false;
    final rows = payload['places'] ?? payload['rows'];
    if (rows is! List || rows.isEmpty) return false;

    final parsed = <Place>[];
    for (final row in rows) {
      final p = Place.tryParse(row);
      if (p != null) parsed.add(p);
    }
    if (parsed.isEmpty) return false;

    // Resolve parent names ONCE here rather than on every storageLabel read —
    // the label is built during list scrolling and post submission, and a map
    // lookup per frame per row is exactly the kind of cost that makes a picker
    // feel cheap instead of instant.
    final byId = {for (final p in parsed) p.id: p};
    final resolved = parsed
        .map((p) => p.kind == PlaceKind.area
            ? p.withParentName(byId[p.parentId]?.name ?? p.county)
            : p)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    _version = version;
    _places = resolved;
    _byId = {for (final p in resolved) p.id: p};
    _byLabel = {for (final p in resolved) normalizeForSearch(p.storageLabel): p};
    _standalone = resolved.where((p) => p.kind != PlaceKind.area).toList();
    _geolocatable = resolved.where((p) => p.hasCoordinates).toList();
    _browseRows = null;
    _index = SearchIndex<Place>(
      resolved,
      name: (p) => p.name,
      weight: (p) => p.rank,
      aliases: (p) => p.aliases,
      // County and parent city match, but only as a last resort: typing
      // "kiambu" should list Kiambu town first and its towns after.
      context: (p) => [p.county, if (p.parentName != null) p.parentName!],
    );
    return true;
  }

  @override
  Future<Map<String, dynamic>?> fetchRemote(int haveVersion) async {
    final newer = await remoteVersionIfNewer('locations:$countryCode', haveVersion);
    if (newer == null) return null;
    try {
      final rows = await Supabase.instance.client
          .from('locations')
          .select('id, name, kind, parent_id, county, is_county_hq, latitude, longitude, rank, aliases, country_code')
          .eq('country_code', countryCode)
          .eq('active', true)
          .timeout(const Duration(seconds: 15));
      if (rows.isEmpty) return null;
      return {
        'schema': 1,
        'version': newer,
        'country': countryCode,
        'places': rows,
      };
    } catch (e) {
      debugPrint('[$debugName] locations fetch failed: $e');
      return null;
    }
  }

  @visibleForTesting
  void seedForTest(List<Place> places, {int version = 1}) {
    _version = 0;
    applyPayload({
      'version': version,
      'places': places.map((p) => p.toCacheMap()).toList(),
    });
  }

  @visibleForTesting
  void resetForTest() {
    _version = 0;
    _places = const [];
    _byId = const {};
    _byLabel = const {};
    _standalone = const [];
    _geolocatable = const [];
    _browseRows = null;
    _index = null;
    resetLoadState();
  }
}

/// Great-circle distance in kilometres. Local rather than Geolocator's so the
/// registry stays plain Dart and unit-testable without platform bindings.
double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusKm = 6371.0088;
  final dLat = _toRad(lat2 - lat1);
  final dLon = _toRad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_toRad(lat1)) * math.cos(_toRad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return earthRadiusKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _toRad(double deg) => deg * math.pi / 180.0;
