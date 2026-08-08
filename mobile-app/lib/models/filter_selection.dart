// `hide Category`: foundation exports a `Category` ANNOTATION that collides with
// the post model's Category class — the same clash category_schema_service.dart
// documents. Hidden rather than prefixed so the rest of the file reads normally.
import 'package:flutter/foundation.dart' hide Category;

import 'post_model.dart';

/// THE FILTER SET, AS ONE VALUE.
///
/// The filter sheet used to apply itself by calling six setters on AppProvider,
/// each of which notified listeners, and the first of which — `clearFilters()` —
/// issued a full ranked feed request with EMPTY filters before the other five
/// had run. The screen then issued a second request on close. Two round trips
/// per apply (measured 0.6–1.2 s each on the S20+), the first always discarded
/// by the request-sequence guard, and one of them fired even when the user
/// cancelled without changing anything.
///
/// Making the selection a value fixes all of that structurally: the sheet
/// returns one of these or returns nothing, and the provider swaps its state in
/// a single step and decides — once — whether a request is even warranted.
///
/// It is also what filter history stores, which is why [signature] and the JSON
/// round-trip live here rather than in the history service: "the same filters"
/// must mean the same thing to deduplication as it does to the feed.
@immutable
class FilterSelection {
  /// Selected category / profession names, in the vocabulary's own spelling.
  ///
  /// Resolved through [Category.resolveFilterName] before they get here, so a
  /// user who typed "cleaning" is holding "Cleaning" — the value the corpus
  /// actually stores and the only one the server's `category = ANY(...)` can
  /// match.
  final Set<String> categories;

  final String city;
  final String area;

  /// Inclusive price bounds in KES. [priceFloor] means "no minimum" and
  /// [priceCeiling] means "no maximum"; the wire contract is unchanged —
  /// `min_price` is sent only above the floor, `max_price` only below the
  /// ceiling.
  final double minPrice;
  final double maxPrice;

  final Urgency? urgency;

  static const double priceFloor = 0;
  static const double priceCeiling = 100000;

  const FilterSelection({
    this.categories = const {},
    this.city = '',
    this.area = '',
    this.minPrice = priceFloor,
    this.maxPrice = priceCeiling,
    this.urgency,
  });

  static const FilterSelection none = FilterSelection();

  bool get hasPriceBound => minPrice > priceFloor || maxPrice < priceCeiling;

  bool get isEmpty =>
      categories.isEmpty &&
      city.isEmpty &&
      area.isEmpty &&
      urgency == null &&
      !hasPriceBound;

  bool get isNotEmpty => !isEmpty;

  FilterSelection copyWith({
    Set<String>? categories,
    String? city,
    String? area,
    double? minPrice,
    double? maxPrice,
    Urgency? urgency,
    bool clearUrgency = false,
  }) {
    return FilterSelection(
      categories: categories ?? this.categories,
      city: city ?? this.city,
      area: area ?? this.area,
      minPrice: minPrice ?? this.minPrice,
      maxPrice: maxPrice ?? this.maxPrice,
      urgency: clearUrgency ? null : (urgency ?? this.urgency),
    );
  }

  /// Canonical identity of this filter set.
  ///
  /// Order-independent (a set of categories is not a list) and case-folded, so
  /// choosing Plumbing then Painting is the same saved filter as choosing
  /// Painting then Plumbing, and reopening a restored filter does not stack a
  /// duplicate onto history.
  String get signature {
    final cats = categories.map((c) => c.toLowerCase()).toList()..sort();
    return [
      'c:${cats.join('|')}',
      'city:${city.toLowerCase()}',
      'area:${area.toLowerCase()}',
      'min:${minPrice.round()}',
      'max:${maxPrice.round()}',
      'u:${urgency?.name ?? ''}',
    ].join(';');
  }

  /// Short human summary for a Recent chip. Never empty for a saved filter,
  /// because an empty selection is never saved.
  String get label {
    final parts = <String>[
      ...categories,
      if (area.isNotEmpty) area else if (city.isNotEmpty) city,
      if (urgency != null) _urgencyLabel(urgency!),
      if (hasPriceBound) _priceLabel,
    ];
    return parts.isEmpty ? 'All posts' : parts.join(' · ');
  }

  String get _priceLabel {
    String k(double v) =>
        v >= 1000 ? '${(v / 1000).toStringAsFixed(v % 1000 == 0 ? 0 : 1)}k' : '${v.round()}';
    if (minPrice <= priceFloor) return 'Under ${k(maxPrice)}';
    if (maxPrice >= priceCeiling) return 'Over ${k(minPrice)}';
    return '${k(minPrice)}–${k(maxPrice)}';
  }

  static String _urgencyLabel(Urgency u) {
    switch (u) {
      case Urgency.urgent:
        return 'High urgency';
      case Urgency.soon:
        return 'Medium urgency';
      case Urgency.flexible:
        return 'Low urgency';
    }
  }

  Map<String, dynamic> toJson() => {
        'categories': categories.toList(),
        'city': city,
        'area': area,
        'min': minPrice,
        'max': maxPrice,
        if (urgency != null) 'urgency': urgency!.name,
      };

  /// Tolerant by design: history is read from disk written by an older build,
  /// and one unreadable entry must never take the whole list with it. Anything
  /// unparseable falls back to a neutral value rather than throwing.
  static FilterSelection? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final cats = raw['categories'];
    final urgencyName = raw['urgency'];
    final selection = FilterSelection(
      categories: cats is List
          ? {
              for (final c in cats)
                if (c is String && c.trim().isNotEmpty) c.trim()
            }
          : const {},
      city: raw['city'] is String ? (raw['city'] as String).trim() : '',
      area: raw['area'] is String ? (raw['area'] as String).trim() : '',
      minPrice: _asPrice(raw['min'], priceFloor),
      maxPrice: _asPrice(raw['max'], priceCeiling),
      urgency: urgencyName is String
          ? Urgency.values.where((u) => u.name == urgencyName).firstOrNull
          : null,
    );
    // An empty selection is not a filter anybody saved; refusing it here keeps
    // a corrupt entry from rendering as a meaningless "All posts" chip.
    return selection.isEmpty ? null : selection;
  }

  static double _asPrice(dynamic v, double fallback) {
    final n = v is num ? v.toDouble() : double.tryParse('$v');
    if (n == null || n.isNaN || n < priceFloor) return fallback;
    return n > priceCeiling ? priceCeiling : n;
  }

  @override
  bool operator ==(Object other) =>
      other is FilterSelection && other.signature == signature;

  @override
  int get hashCode => signature.hashCode;

  @override
  String toString() => 'FilterSelection($signature)';
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// PRICE, THE WAY HELP24 IS ACTUALLY PRICED.
///
/// The old control was a 0–100,000 KES range slider with 20 divisions, so its
/// smallest step was 5,000 KES. Against production — median 600, maximum 4,500 —
/// that meant moving the minimum handle one notch emptied the feed completely,
/// and moving the maximum handle did nothing at all until it fell below 5,000.
/// Every real Help24 listing lived inside the first step.
///
/// Bands instead of a slider: they name the amounts people actually quote
/// (300, 500, 1,000, 2,500…), they are one tap on a phone, and each maps
/// straight onto the existing `min_price` / `max_price` wire contract with no
/// backend change. The bottom band is a maximum only, the top band a minimum
/// only, and the rest are both — so all three cases stay expressible.
@immutable
class PriceBand {
  final String label;
  final double min;
  final double max;

  const PriceBand(this.label, this.min, this.max);

  bool get isAny =>
      min <= FilterSelection.priceFloor && max >= FilterSelection.priceCeiling;

  bool matches(FilterSelection s) => s.minPrice == min && s.maxPrice == max;

  static const List<PriceBand> all = [
    PriceBand('Any price', FilterSelection.priceFloor, FilterSelection.priceCeiling),
    PriceBand('Under 500', FilterSelection.priceFloor, 500),
    PriceBand('500 – 1,000', 500, 1000),
    PriceBand('1,000 – 2,500', 1000, 2500),
    PriceBand('2,500 – 5,000', 2500, 5000),
    PriceBand('5,000 – 10,000', 5000, 10000),
    PriceBand('10,000 – 50,000', 10000, 50000),
    PriceBand('Over 50,000', 50000, FilterSelection.priceCeiling),
  ];

  /// The band a selection sits in, or null when it came from somewhere else
  /// (a restored history entry written by a build with different bands). The
  /// UI shows no band selected rather than lying about which one is active.
  static PriceBand? forSelection(FilterSelection s) {
    for (final band in all) {
      if (band.matches(s)) return band;
    }
    return null;
  }
}
