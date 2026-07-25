import 'package:flutter/foundation.dart';

/// What kind of place this is. Drives grouping, iconography and — importantly —
/// which entries are candidates for "snap my GPS fix to a known town".
enum PlaceKind {
  /// A major urban centre. Always a valid standalone location.
  city,

  /// A town, municipality or county headquarters. Standalone.
  town,

  /// A neighbourhood/estate inside a city. Never standalone: it always renders
  /// and stores as "Area, City".
  area,
}

PlaceKind _kindFromCode(String? code) {
  switch (code) {
    case 'city':
      return PlaceKind.city;
    case 'area':
      return PlaceKind.area;
    default:
      return PlaceKind.town;
  }
}

String kindCode(PlaceKind kind) => switch (kind) {
      PlaceKind.city => 'city',
      PlaceKind.area => 'area',
      PlaceKind.town => 'town',
    };

/// One entry in the location registry.
///
/// WHY THIS EXISTS AND `KenyaLocation` DID NOT SURVIVE AS THE MODEL
/// ---------------------------------------------------------------
/// The old model was a (city, area) tuple hardcoded in the post model. It could
/// not express a county, a coordinate, an alias, a country, or "this town has
/// no neighbourhoods" — which is most of Kenya. Every town outside Nairobi and
/// Mombasa was therefore given a fake area called "Town Centre" so the tuple
/// could exist at all.
///
/// A Place is the smallest shape that supports the product for the next few
/// years: it names itself, knows where it sits administratively, optionally
/// knows where it sits on Earth, and carries the search aliases people actually
/// type. Adding a country means adding rows, not fields.
///
/// STORAGE CONTRACT (do not change lightly)
/// ----------------------------------------
/// [storageLabel] is what lands in `posts.location`, and it reproduces the
/// EXACT string shape the app has always written ("Westlands, Nairobi" /
/// "Naivasha"). Every existing post, every `ilike '%city%'` filter and every
/// card that prints `post.location` keeps working untouched.
@immutable
class Place {
  /// Stable slug. Never rename — it is the join key between the bundled asset,
  /// the device cache and the server table.
  final String id;

  /// Display name on its own ("Westlands", "Naivasha").
  final String name;

  final PlaceKind kind;

  /// Parent place id for [PlaceKind.area]; null otherwise.
  final String? parentId;

  /// Resolved parent name, filled in by the registry after the list is loaded
  /// so [storageLabel] never has to do a lookup mid-build.
  final String? parentName;

  /// County (Kenya) / first-level administrative division elsewhere.
  final String county;

  /// True for the 47 county headquarters — surfaced in browse ordering because
  /// a county HQ is almost always the right answer for its region.
  final bool isCountyHq;

  /// Present only where a trustworthy coordinate exists (cities, towns, a few
  /// large estates). Never invented: a missing coordinate simply excludes the
  /// entry from distance-based snapping, which is the correct behaviour.
  final double? latitude;
  final double? longitude;

  /// Search/browse weight. Higher wins ties.
  final int rank;

  /// Extra strings people type for this place ("msa", "diani beach", "kibra").
  final List<String> aliases;

  /// ISO-3166-1 alpha-2. The seam for the next country.
  final String countryCode;

  const Place({
    required this.id,
    required this.name,
    required this.kind,
    required this.county,
    this.parentId,
    this.parentName,
    this.isCountyHq = false,
    this.latitude,
    this.longitude,
    this.rank = 300,
    this.aliases = const [],
    this.countryCode = 'KE',
  });

  bool get hasCoordinates => latitude != null && longitude != null;

  /// The city this place belongs to — itself, unless it is a neighbourhood.
  /// This is the value the city filter compares against.
  String get cityName => kind == PlaceKind.area ? (parentName ?? county) : name;

  /// The neighbourhood component, or null for standalone towns/cities.
  String? get areaName => kind == PlaceKind.area ? name : null;

  /// What is written to `posts.location` and rendered on cards.
  /// Byte-compatible with what the app wrote before this registry existed.
  String get storageLabel =>
      kind == PlaceKind.area ? '$name, ${parentName ?? county}' : name;

  /// Secondary line in pickers: "Nairobi · Nairobi County" style context.
  String get subtitle {
    if (kind == PlaceKind.area) {
      return '${parentName ?? county} · $county County';
    }
    if (isCountyHq) return '$county County · County HQ';
    return '$county County';
  }

  /// Letter this place files under in the alphabetical browse list.
  String get sectionLetter {
    final first = name.trim().isEmpty ? '#' : name.trim()[0].toUpperCase();
    return RegExp(r'[A-Z]').hasMatch(first) ? first : '#';
  }

  Place withParentName(String? resolved) => Place(
        id: id,
        name: name,
        kind: kind,
        county: county,
        parentId: parentId,
        parentName: resolved,
        isCountyHq: isCountyHq,
        latitude: latitude,
        longitude: longitude,
        rank: rank,
        aliases: aliases,
        countryCode: countryCode,
      );

  /// Parses BOTH shapes the app ever sees:
  ///   • the compact bundled/cached asset row ({"i","n","t","p","c","hq",...})
  ///   • a Supabase `locations` row ({"id","name","kind","parent_id",...})
  /// One parser, because the cache is written from whichever source produced
  /// it and must round-trip identically.
  static Place? tryParse(dynamic row) {
    if (row is! Map) return null;
    final id = (row['i'] ?? row['id']);
    final name = (row['n'] ?? row['name']);
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    final rank = row['r'] ?? row['rank'];
    return Place(
      id: id,
      name: name,
      kind: _kindFromCode((row['t'] ?? row['kind']) as String?),
      parentId: (row['p'] ?? row['parent_id']) as String?,
      county: ((row['c'] ?? row['county']) as String?)?.trim() ?? '',
      isCountyHq: (row['hq'] ?? row['is_county_hq']) == true,
      latitude: _toDouble(row['lat'] ?? row['latitude']),
      longitude: _toDouble(row['lng'] ?? row['longitude']),
      rank: rank is int ? rank : 300,
      aliases: _toStringList(row['a'] ?? row['aliases']),
      countryCode:
          ((row['cc'] ?? row['country_code']) as String?)?.toUpperCase() ?? 'KE',
    );
  }

  /// Compact form — what gets cached. Same keys as the bundled asset so the
  /// cache and the asset are interchangeable inputs.
  Map<String, dynamic> toCacheMap() => {
        'i': id,
        'n': name,
        't': kindCode(kind),
        if (parentId != null) 'p': parentId,
        'c': county,
        if (isCountyHq) 'hq': true,
        if (latitude != null) 'lat': latitude,
        if (longitude != null) 'lng': longitude,
        'r': rank,
        if (aliases.isNotEmpty) 'a': aliases,
        'cc': countryCode,
      };

  @override
  bool operator ==(Object other) => other is Place && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Place($id)';
}

double? _toDouble(dynamic v) => v is num ? v.toDouble() : null;

List<String> _toStringList(dynamic v) {
  if (v is! List) return const [];
  return v.whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}

/// How a location came to be attached to a post or profile.
enum LocationSource {
  /// The user picked it from the list.
  manual,

  /// GPS fix, reverse-geocoded to a name.
  gps,

  /// GPS fix with no geocoder answer, named by snapping to the nearest known
  /// town in the registry. Still a real location — just named offline.
  gpsSnapped,
}

/// The result of choosing a location: everything a post, a filter and a card
/// need, in one immutable value.
///
/// [label] is the ONLY thing written to `posts.location`, and it is always a
/// human-readable place name — never coordinates, never a slug. That is what
/// keeps every existing post, filter and card working while coordinates ride
/// along in their own columns.
@immutable
class LocationSelection {
  /// Goes to `posts.location`. "Westlands, Nairobi", "Naivasha", "Mtopanga,
  /// Mombasa" — whatever a person would actually say.
  final String label;

  /// The city component, used by city filters and by feed prioritisation.
  final String cityName;

  /// The neighbourhood component, when there is one.
  final String? areaName;

  /// Registry id when this resolved to a known place; null for a GPS name that
  /// matched nothing in the registry (still perfectly valid to post with).
  final String? placeId;

  final double? latitude;
  final double? longitude;

  final LocationSource source;

  const LocationSelection({
    required this.label,
    required this.cityName,
    this.areaName,
    this.placeId,
    this.latitude,
    this.longitude,
    this.source = LocationSource.manual,
  });

  bool get hasCoordinates => latitude != null && longitude != null;

  bool get isFromDevice =>
      source == LocationSource.gps || source == LocationSource.gpsSnapped;

  factory LocationSelection.fromPlace(Place place) => LocationSelection(
        label: place.storageLabel,
        cityName: place.cityName,
        areaName: place.areaName,
        placeId: place.id,
        latitude: place.latitude,
        longitude: place.longitude,
      );

  LocationSelection copyWith({double? latitude, double? longitude}) =>
      LocationSelection(
        label: label,
        cityName: cityName,
        areaName: areaName,
        placeId: placeId,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        source: source,
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'city': cityName,
        if (areaName != null) 'area': areaName,
        if (placeId != null) 'placeId': placeId,
        if (latitude != null) 'lat': latitude,
        if (longitude != null) 'lng': longitude,
        'source': source.name,
      };

  static LocationSelection? fromJson(dynamic json) {
    if (json is! Map) return null;
    final label = (json['label'] as String?)?.trim();
    if (label == null || label.isEmpty) return null;
    return LocationSelection(
      label: label,
      cityName: (json['city'] as String?)?.trim().isNotEmpty == true
          ? (json['city'] as String).trim()
          : label,
      areaName: (json['area'] as String?)?.trim(),
      placeId: json['placeId'] as String?,
      latitude: _toDouble(json['lat']),
      longitude: _toDouble(json['lng']),
      source: LocationSource.values.firstWhere(
        (s) => s.name == json['source'],
        orElse: () => LocationSource.manual,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LocationSelection &&
      other.label == label &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(label, latitude, longitude);
}
