import 'dart:convert';

// NOTE: material.dart re-exports foundation's debugPrint, but foundation also
// exports a `Category` annotation that clashes with the post model's Category —
// so material is imported plainly and foundation is not imported at all.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/category_schema.dart';
import '../models/post_model.dart';

/// Smart Posting (SP-1): the category registry client.
///
/// Source of truth is the server `categories` table (name, icon, sort,
/// question_schema). Resilience contract, in order:
///   1. serve from memory,
///   2. serve from the SharedPreferences cache (24h TTL; stale cache is still
///      used if the network fails),
///   3. fall back to the bundled [Category.all] list with NO schemas — i.e.
///      exactly today's generic form.
/// The schema layer must never block or delay posting: [warmUp] is fire-and-
/// forget, and every getter answers synchronously from whatever is loaded.
class CategorySchemaService {
  CategorySchemaService._();
  static final CategorySchemaService instance = CategorySchemaService._();

  static const _cacheKey = 'category_registry_cache_v1';
  static const _cacheAtKey = 'category_registry_cached_at_v1';
  static const _ttl = Duration(hours: 24);

  List<Category>? _categories; // built Category objects (stable instances)
  Map<String, QuestionSchema>? _schemasByName; // category name → schema
  Map<String, int>? _versionsByName;
  Future<void>? _inflight;

  /// Category list for the posting dropdown. Falls back to the bundled list.
  List<Category> get categories => _categories ?? Category.all;

  /// The question schema for a category name, or null → generic form.
  QuestionSchema? schemaFor(String categoryName) =>
      _schemasByName?[categoryName.toLowerCase()];

  int schemaVersionFor(String categoryName) =>
      _versionsByName?[categoryName.toLowerCase()] ?? 1;

  /// Load cache then refresh from the server if stale. Safe to call often;
  /// concurrent calls share one in-flight future. Never throws.
  Future<void> warmUp() {
    return _inflight ??= _load().whenComplete(() => _inflight = null);
  }

  Future<void> _load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      final cachedAtMs = prefs.getInt(_cacheAtKey) ?? 0;
      final cachedAt = DateTime.fromMillisecondsSinceEpoch(cachedAtMs);
      if (cached != null && _categories == null) {
        _apply(jsonDecode(cached));
      }
      final fresh = DateTime.now().difference(cachedAt) < _ttl;
      if (fresh && _categories != null) return;
    } catch (e) {
      debugPrint('[CATEGORY_REGISTRY] cache read failed: $e');
    }

    try {
      final rows = await Supabase.instance.client
          .from('categories')
          .select('id, name, icon, sort, question_schema, schema_version')
          .eq('active', true)
          .order('sort', ascending: true);
      _apply(rows);
      await prefs?.setString(_cacheKey, jsonEncode(rows));
      await prefs?.setInt(_cacheAtKey, DateTime.now().millisecondsSinceEpoch);
      debugPrint('[CATEGORY_REGISTRY] loaded ${rows.length} categories from server');
    } catch (e) {
      // Table missing (migration 070 not applied), offline, etc. — the cached
      // or bundled list stays in effect. Posting is unaffected.
      debugPrint('[CATEGORY_REGISTRY] fetch failed (using ${_categories == null ? 'bundled list' : 'cache'}): $e');
    }
  }

  void _apply(dynamic rows) {
    if (rows is! List || rows.isEmpty) return;
    final categories = <Category>[];
    final schemas = <String, QuestionSchema>{};
    final versions = <String, int>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final name = row['name'];
      if (name is! String || name.isEmpty) continue;
      categories.add(Category(name: name, icon: _iconFor(row['icon'] as String?)));
      final schema = QuestionSchema.tryParse(row['question_schema']);
      if (schema != null) {
        schemas[name.toLowerCase()] = schema;
        versions[name.toLowerCase()] =
            row['schema_version'] is int ? row['schema_version'] as int : schema.version;
      }
    }
    if (categories.isEmpty) return;
    _categories = categories;
    _schemasByName = schemas;
    _versionsByName = versions;
  }

  /// Server icon keys → Material icons (same set used by [Category.all]).
  /// Unknown keys get a sane default so new server categories render fine
  /// on old app versions.
  static IconData _iconFor(String? key) =>
      _iconMap[key] ?? Icons.work_outline;

  static const Map<String, IconData> _iconMap = {
    'plumbing': Icons.plumbing,
    'electrical_services': Icons.electrical_services,
    'foundation': Icons.foundation,
    'handyman': Icons.handyman,
    'format_paint': Icons.format_paint,
    'construction': Icons.construction,
    'cleaning_services': Icons.cleaning_services,
    'local_laundry_service': Icons.local_laundry_service,
    'grass': Icons.grass,
    'security': Icons.security,
    'directions_car': Icons.directions_car,
    'delivery_dining': Icons.delivery_dining,
    'car_repair': Icons.car_repair,
    'local_car_wash': Icons.local_car_wash,
    'kitchen': Icons.kitchen,
    'ac_unit': Icons.ac_unit,
    'phone_android': Icons.phone_android,
    'computer': Icons.computer,
    'brush': Icons.brush,
    'code': Icons.code,
    'camera_alt': Icons.camera_alt,
    'videocam': Icons.videocam,
    'celebration': Icons.celebration,
    'restaurant': Icons.restaurant,
    'school': Icons.school,
    'child_care': Icons.child_care,
    'favorite': Icons.favorite,
    'move_up': Icons.move_up,
    'chair': Icons.chair,
    'architecture': Icons.architecture,
    'engineering': Icons.engineering,
    'more_horiz': Icons.more_horiz,
  };
}
