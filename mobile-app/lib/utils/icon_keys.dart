import 'package:flutter/material.dart';

/// Server icon keys → Material icons.
///
/// The server registries (`categories`, `professions`) store an icon as a
/// STRING key rather than a code point, so a row added in SQL renders on
/// clients that were built before that row existed. Unknown keys fall back to
/// a sane default — a new server category/profession must never render a
/// broken glyph on an older app build.
///
/// Extracted from CategorySchemaService so the profession registry uses the
/// exact same vocabulary instead of maintaining a second copy.
IconData iconForKey(String? key, {IconData fallback = Icons.work_outline}) =>
    _iconMap[key] ?? fallback;

const Map<String, IconData> _iconMap = {
  // ── Home & property ────────────────────────────────────────────────────
  'plumbing': Icons.plumbing,
  'electrical_services': Icons.electrical_services,
  'foundation': Icons.foundation,
  'handyman': Icons.handyman,
  'format_paint': Icons.format_paint,
  'construction': Icons.construction,
  'architecture': Icons.architecture,
  'engineering': Icons.engineering,
  'chair': Icons.chair,
  // ── Cleaning & household ───────────────────────────────────────────────
  'cleaning_services': Icons.cleaning_services,
  'local_laundry_service': Icons.local_laundry_service,
  'grass': Icons.grass,
  // ── Security & transport ───────────────────────────────────────────────
  'security': Icons.security,
  'directions_car': Icons.directions_car,
  'delivery_dining': Icons.delivery_dining,
  'move_up': Icons.move_up,
  // ── Automotive ─────────────────────────────────────────────────────────
  'car_repair': Icons.car_repair,
  'local_car_wash': Icons.local_car_wash,
  // ── Appliance & tech repair ────────────────────────────────────────────
  'kitchen': Icons.kitchen,
  'ac_unit': Icons.ac_unit,
  'phone_android': Icons.phone_android,
  'computer': Icons.computer,
  // ── Creative & digital ─────────────────────────────────────────────────
  'brush': Icons.brush,
  'code': Icons.code,
  'camera_alt': Icons.camera_alt,
  'videocam': Icons.videocam,
  // ── Events & hospitality ───────────────────────────────────────────────
  'celebration': Icons.celebration,
  'restaurant': Icons.restaurant,
  'content_cut': Icons.content_cut,
  'checkroom': Icons.checkroom,
  // ── Education & care ───────────────────────────────────────────────────
  'school': Icons.school,
  'child_care': Icons.child_care,
  'favorite': Icons.favorite,
  // ── Profession-catalogue category icons (migration 089) ────────────────
  // One icon per CATEGORY rather than per profession: a profession with no
  // icon of its own inherits its category's, so a catalogue of hundreds needs
  // ~34 glyphs instead of hundreds. Adding a category later still only needs
  // a key that already exists here — an unknown key degrades, never breaks.
  'home_repair_service': Icons.home_repair_service,
  'medical_services': Icons.medical_services,
  'rocket_launch': Icons.rocket_launch,
  'campaign': Icons.campaign,
  'agriculture': Icons.agriculture,
  'local_shipping': Icons.local_shipping,
  'precision_manufacturing': Icons.precision_manufacturing,
  'business_center': Icons.business_center,
  'account_balance': Icons.account_balance,
  'gavel': Icons.gavel,
  'apartment': Icons.apartment,
  'volunteer_activism': Icons.volunteer_activism,
  'church': Icons.church,
  'sports_soccer': Icons.sports_soccer,
  'theater_comedy': Icons.theater_comedy,
  'pets': Icons.pets,
  'solar_power': Icons.solar_power,
  // ── Fallback ───────────────────────────────────────────────────────────
  'more_horiz': Icons.more_horiz,
};
