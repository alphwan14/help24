import 'package:flutter/material.dart';

import '../utils/icon_keys.dart';

/// A group of professions ("Skilled Trades", "IT & Software").
///
/// A flat alphabetical list stops working somewhere around fifty entries: the
/// catalogue is now in the hundreds, so browsing needs structure and search
/// needs something to match against besides the exact job title. Categories are
/// that structure — and, like professions, they are server-driven, so a new one
/// is an INSERT rather than an app release.
@immutable
class ProfessionCategory {
  /// Stable slug ("skilled-trades"). Stored on each profession.
  final String id;

  /// Display label ("Skilled Trades").
  final String name;

  /// Icon key ([iconForKey]); professions without their own icon inherit it.
  final String? iconKey;

  /// Ordering across categories (lower first).
  final int sort;

  /// Cross-cutting labels — `wc` white collar, `bc` blue collar, `fl`
  /// freelance-friendly, `em` emerging/digital. Deliberately tags rather than
  /// categories: a Software Engineer is white collar AND freelance AND
  /// emerging, and none of those is its taxonomy. Professions inherit these
  /// unless they override them, so "freelance" is searchable without stamping
  /// four flags onto five hundred rows.
  final List<String> tags;

  const ProfessionCategory({
    required this.id,
    required this.name,
    this.iconKey,
    this.sort = 500,
    this.tags = const [],
  });

  IconData get icon => iconForKey(iconKey);

  static ProfessionCategory? tryParse(dynamic row) {
    if (row is! Map) return null;
    final id = row['i'] ?? row['id'];
    final name = row['n'] ?? row['name'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    final sort = row['s'] ?? row['sort'];
    return ProfessionCategory(
      id: id,
      name: name,
      iconKey: (row['icon']) as String?,
      sort: sort is int ? sort : 500,
      tags: _stringList(row['t'] ?? row['tags']),
    );
  }

  Map<String, dynamic> toCacheMap() => {
        'i': id,
        'n': name,
        if (iconKey != null) 'icon': iconKey,
        's': sort,
        if (tags.isNotEmpty) 't': tags,
      };

  @override
  bool operator ==(Object other) => other is ProfessionCategory && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A profession from the controlled vocabulary (server table `professions`,
/// migrations 086 + 089; bundled JSON asset as the offline fallback).
///
/// WHY A KEY AND NOT FREE TEXT
/// ---------------------------
/// `users.profession` used to hold whatever the user typed, which produced
/// "electrician", "Electrician", "Electrical", "Electrical Works" and "electric"
/// as five distinct values. Provider search, filtering, matching, and analytics
/// all need ONE canonical value per trade, so the column stores [id] — a stable
/// slug that never changes — and the label is resolved for display.
///
/// Legacy free text is NOT destroyed: a value that resolves to no profession is
/// still shown verbatim (see ProfessionRegistry.resolve / labelFor), it simply
/// does not count as a completed profile field. That nudges migration without
/// breaking a single existing user.
@immutable
class Profession {
  /// Stable slug stored in `users.profession`. Never rename an existing id.
  final String id;

  /// Display label ("Electrician").
  final String name;

  /// Icon key understood by [iconForKey]. Null → inherit the category's icon,
  /// which is why five hundred professions do not need five hundred glyphs.
  final String? iconKey;

  /// Ordering hint. Retained for the 086-era rows and for admin overrides;
  /// browse order is (category sort, name) so the catalogue stays alphabetical
  /// inside each category no matter what is inserted later.
  final int sort;

  /// Category slug ([ProfessionCategory.id]).
  final String categoryGroupId;

  /// Optional link to a `categories.id` — the seam for provider↔request
  /// matching ("show Electricians for this Electrical request").
  final String? categoryId;

  /// What people actually type, including Kiswahili and local terms ("fundi",
  /// "mama fua", "boda"). The single highest-value field in the catalogue: it
  /// is the difference between a provider finding their trade and giving up.
  final List<String> aliases;

  /// Cross-cutting tags; empty means "inherit the category's".
  final List<String> tags;

  /// Search weight. Breaks ties so that a query matching several titles equally
  /// well surfaces the common Kenyan trade first — "electr" should lead with
  /// Electrician, not Electrical Engineer, and "mason" should not have to
  /// compete alphabetically with Masonry Contractor.
  final int weight;

  /// ISO-3166-1 alpha-2 country scope, or null for "every country". Kenya-first
  /// without being Kenya-only: a future market adds its own rows and the
  /// registry filters them in.
  final String? countryCode;

  const Profession({
    required this.id,
    required this.name,
    this.iconKey,
    this.sort = 100,
    this.categoryGroupId = 'other',
    this.categoryId,
    this.aliases = const [],
    this.tags = const [],
    this.weight = 500,
    this.countryCode,
  });

  IconData get icon => iconForKey(iconKey);

  /// Identity is the slug — registry refreshes rebuild instances, and pickers
  /// need `value == item` to hold across a refresh.
  @override
  bool operator ==(Object other) => other is Profession && other.id == id;

  @override
  int get hashCode => id.hashCode;

  /// Parses BOTH the compact asset/cache row and a Supabase `professions` row.
  static Profession? tryParse(dynamic row) {
    if (row is! Map) return null;
    final id = row['i'] ?? row['id'];
    final name = row['n'] ?? row['name'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    final sort = row['sort'];
    final weight = row['w'] ?? row['weight'];
    return Profession(
      id: id,
      name: name,
      iconKey: (row['icon']) as String?,
      sort: sort is int ? sort : 100,
      weight: weight is int ? weight : 500,
      categoryGroupId:
          ((row['g'] ?? row['group_id']) as String?)?.trim().isNotEmpty == true
              ? (row['g'] ?? row['group_id']) as String
              : 'other',
      categoryId: (row['c'] ?? row['category_id']) as String?,
      aliases: _stringList(row['a'] ?? row['aliases']),
      tags: _stringList(row['t'] ?? row['tags']),
      countryCode: ((row['cc'] ?? row['country_code']) as String?)?.toUpperCase(),
    );
  }

  Map<String, dynamic> toCacheMap() => {
        'i': id,
        'n': name,
        if (iconKey != null) 'icon': iconKey,
        'sort': sort,
        'g': categoryGroupId,
        if (categoryId != null) 'c': categoryId,
        if (aliases.isNotEmpty) 'a': aliases,
        if (tags.isNotEmpty) 't': tags,
        'w': weight,
        if (countryCode != null) 'cc': countryCode,
      };

  /// The slug used for "none of these". Keeping it out of "is this a real
  /// trade?" checks would be wrong — picking Other IS a deliberate answer, so
  /// it counts as complete. It is simply always sorted last.
  static const String otherId = 'other';

  /// Minimal in-code fallback: the ORIGINAL seventeen ids from migration 086.
  ///
  /// The real catalogue is `assets/data/professions.json` (hundreds of entries,
  /// grouped and aliased) and is loaded on the first frame. This list exists
  /// only for the instant before that asset resolves and for unit tests that do
  /// not run an asset bundle — so it holds exactly the ids that have been
  /// stored in `users.profession` since 086, guaranteeing every existing
  /// profile resolves even in that window.
  static const List<Profession> bundled = [
    Profession(id: 'electrician', name: 'Electrician', iconKey: 'electrical_services', sort: 10, categoryGroupId: 'skilled-trades', categoryId: 'electrical', weight: 900),
    Profession(id: 'plumber', name: 'Plumber', iconKey: 'plumbing', sort: 20, categoryGroupId: 'skilled-trades', categoryId: 'plumbing', weight: 900),
    Profession(id: 'mechanic', name: 'Mechanic', iconKey: 'car_repair', sort: 30, categoryGroupId: 'automotive', categoryId: 'mechanic', weight: 900),
    Profession(id: 'cleaner', name: 'Cleaner', iconKey: 'cleaning_services', sort: 40, categoryGroupId: 'cleaning', categoryId: 'house-cleaning', weight: 900),
    Profession(id: 'tutor', name: 'Tutor', iconKey: 'school', sort: 50, categoryGroupId: 'education', categoryId: 'tutoring', weight: 900),
    Profession(id: 'driver', name: 'Driver', iconKey: 'directions_car', sort: 60, categoryGroupId: 'logistics', categoryId: 'driver', weight: 900),
    Profession(id: 'welder', name: 'Welder', iconKey: 'construction', sort: 70, categoryGroupId: 'skilled-trades', categoryId: 'welding', weight: 900),
    Profession(id: 'builder', name: 'Builder', iconKey: 'architecture', sort: 80, categoryGroupId: 'construction', categoryId: 'construction', weight: 900),
    Profession(id: 'painter', name: 'Painter', iconKey: 'format_paint', sort: 90, categoryGroupId: 'construction', categoryId: 'painting', weight: 900),
    Profession(id: 'carpenter', name: 'Carpenter', iconKey: 'handyman', sort: 100, categoryGroupId: 'skilled-trades', categoryId: 'carpentry', weight: 900),
    Profession(id: 'it-technician', name: 'IT Technician', iconKey: 'computer', sort: 110, categoryGroupId: 'it', categoryId: 'computer-repair', weight: 900),
    Profession(id: 'photographer', name: 'Photographer', iconKey: 'camera_alt', sort: 120, categoryGroupId: 'photography', categoryId: 'photography', weight: 900),
    Profession(id: 'salon-beauty', name: 'Salon & Beauty', iconKey: 'content_cut', sort: 130, categoryGroupId: 'beauty', weight: 900),
    Profession(id: 'tailor', name: 'Tailor', iconKey: 'checkroom', sort: 140, categoryGroupId: 'skilled-trades', weight: 900),
    Profession(id: 'cook', name: 'Cook', iconKey: 'restaurant', sort: 150, categoryGroupId: 'hospitality', categoryId: 'catering', weight: 900),
    Profession(id: 'moving-services', name: 'Moving Services', iconKey: 'move_up', sort: 160, categoryGroupId: 'logistics', categoryId: 'moving-services', weight: 900),
    Profession(id: otherId, name: 'Other', iconKey: 'more_horiz', sort: 999, categoryGroupId: 'other'),
  ];

  /// Categories referenced by [bundled], so the fallback window still groups.
  static const List<ProfessionCategory> bundledCategories = [
    ProfessionCategory(id: 'skilled-trades', name: 'Skilled Trades', iconKey: 'handyman', sort: 10),
    ProfessionCategory(id: 'construction', name: 'Construction & Building', iconKey: 'construction', sort: 20),
    ProfessionCategory(id: 'automotive', name: 'Automotive', iconKey: 'car_repair', sort: 40),
    ProfessionCategory(id: 'cleaning', name: 'Cleaning', iconKey: 'cleaning_services', sort: 50),
    ProfessionCategory(id: 'beauty', name: 'Beauty & Personal Care', iconKey: 'content_cut', sort: 60),
    ProfessionCategory(id: 'education', name: 'Education & Training', iconKey: 'school', sort: 80),
    ProfessionCategory(id: 'it', name: 'IT & Software', iconKey: 'computer', sort: 90),
    ProfessionCategory(id: 'photography', name: 'Photography', iconKey: 'camera_alt', sort: 130),
    ProfessionCategory(id: 'hospitality', name: 'Hospitality & Food', iconKey: 'restaurant', sort: 160),
    ProfessionCategory(id: 'logistics', name: 'Logistics & Transport', iconKey: 'local_shipping', sort: 170),
    ProfessionCategory(id: 'other', name: 'Other', iconKey: 'more_horiz', sort: 999),
  ];
}

List<String> _stringList(dynamic v) {
  if (v is! List) return const [];
  return v.whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}
