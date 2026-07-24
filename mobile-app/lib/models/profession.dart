import 'package:flutter/material.dart';

import '../utils/icon_keys.dart';

/// A profession from the controlled vocabulary (server table `professions`,
/// migration 086; bundled fallback below).
///
/// WHY A KEY AND NOT FREE TEXT
/// ---------------------------
/// `users.profession` used to hold whatever the user typed, which produced
/// "electrician", "Electrician", "Electrical", "Electrical Works", "electric"
/// as five distinct values. Provider search, filtering, matching, and analytics
/// all need ONE canonical value per trade, so the column now stores [id] — a
/// stable slug that never changes — and the label is resolved for display.
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

  /// Icon key understood by [iconForKey]; unknown keys degrade to a default.
  final String? iconKey;

  /// Ordering hint from the registry (lower first).
  final int sort;

  /// Optional link to a `categories.id` — the seam for future provider↔request
  /// matching ("show Electricians for this Electrical request"). Not used by
  /// any UI yet; carried so the join exists the day matching ships.
  final String? categoryId;

  const Profession({
    required this.id,
    required this.name,
    this.iconKey,
    this.sort = 100,
    this.categoryId,
  });

  IconData get icon => iconForKey(iconKey);

  /// Identity is the slug — registry refreshes rebuild instances, and pickers
  /// need `value == item` to hold across a refresh.
  @override
  bool operator ==(Object other) => other is Profession && other.id == id;

  @override
  int get hashCode => id.hashCode;

  static Profession? tryParse(dynamic row) {
    if (row is! Map) return null;
    final id = row['id'];
    final name = row['name'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    return Profession(
      id: id,
      name: name,
      iconKey: row['icon'] as String?,
      sort: row['sort'] is int ? row['sort'] as int : 100,
      categoryId: row['category_id'] as String?,
    );
  }

  Map<String, dynamic> toCacheMap() => {
        'id': id,
        'name': name,
        'icon': iconKey,
        'sort': sort,
        'category_id': categoryId,
      };

  /// The slug used for "none of these". Kept out of "is this a real trade?"
  /// checks would be wrong — picking Other IS a deliberate answer, so it
  /// counts as complete. It is simply always sorted last.
  static const String otherId = 'other';

  /// Bundled fallback — byte-identical ids/names to the 086 seed.
  ///
  /// Ships with the app so the profession selector works fully before the
  /// migration is applied, offline, or if the table read fails. Same
  /// resilience contract as [Category.all] for the category registry.
  static const List<Profession> bundled = [
    Profession(id: 'electrician', name: 'Electrician', iconKey: 'electrical_services', sort: 10, categoryId: 'electrical'),
    Profession(id: 'plumber', name: 'Plumber', iconKey: 'plumbing', sort: 20, categoryId: 'plumbing'),
    Profession(id: 'mechanic', name: 'Mechanic', iconKey: 'car_repair', sort: 30, categoryId: 'mechanic'),
    Profession(id: 'cleaner', name: 'Cleaner', iconKey: 'cleaning_services', sort: 40, categoryId: 'house-cleaning'),
    Profession(id: 'tutor', name: 'Tutor', iconKey: 'school', sort: 50, categoryId: 'tutoring'),
    Profession(id: 'driver', name: 'Driver', iconKey: 'directions_car', sort: 60, categoryId: 'driver'),
    Profession(id: 'welder', name: 'Welder', iconKey: 'construction', sort: 70, categoryId: 'welding'),
    Profession(id: 'builder', name: 'Builder', iconKey: 'architecture', sort: 80, categoryId: 'construction'),
    Profession(id: 'painter', name: 'Painter', iconKey: 'format_paint', sort: 90, categoryId: 'painting'),
    Profession(id: 'carpenter', name: 'Carpenter', iconKey: 'handyman', sort: 100, categoryId: 'carpentry'),
    Profession(id: 'it-technician', name: 'IT Technician', iconKey: 'computer', sort: 110, categoryId: 'computer-repair'),
    Profession(id: 'photographer', name: 'Photographer', iconKey: 'camera_alt', sort: 120, categoryId: 'photography'),
    Profession(id: 'salon-beauty', name: 'Salon & Beauty', iconKey: 'content_cut', sort: 130),
    Profession(id: 'tailor', name: 'Tailor', iconKey: 'checkroom', sort: 140),
    Profession(id: 'cook', name: 'Cook', iconKey: 'restaurant', sort: 150, categoryId: 'catering'),
    Profession(id: 'moving-services', name: 'Moving Services', iconKey: 'move_up', sort: 160, categoryId: 'moving-services'),
    Profession(id: otherId, name: 'Other', iconKey: 'more_horiz', sort: 999),
  ];
}
