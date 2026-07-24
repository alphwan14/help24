import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/profession.dart';

/// The controlled-vocabulary client for professions.
///
/// Source of truth is the server `professions` table (migration 086). Adding a
/// profession later is one SQL INSERT — no app release, no code change.
///
/// Resilience contract (identical to CategorySchemaService, deliberately):
///   1. serve from memory,
///   2. serve from the SharedPreferences cache (24h TTL; a stale cache is
///      still used when the network fails),
///   3. fall back to [Profession.bundled].
/// Every getter answers SYNCHRONOUSLY from whatever is loaded, and [warmUp] is
/// fire-and-forget — the profession selector must never block or spin.
class ProfessionRegistry {
  ProfessionRegistry._();
  static final ProfessionRegistry instance = ProfessionRegistry._();

  static const _cacheKey = 'profession_registry_cache_v1';
  static const _cacheAtKey = 'profession_registry_cached_at_v1';
  static const _ttl = Duration(hours: 24);

  List<Profession>? _professions;
  Map<String, Profession>? _byId;
  Future<void>? _inflight;

  /// Every active profession, registry order (sort asc, "Other" last).
  List<Profession> get all => _professions ?? Profession.bundled;

  /// Resolve a stored `users.profession` value to a known profession.
  ///
  /// Returns null for empty values AND for legacy free text ("Electrical
  /// Works") that matches no id. Callers MUST treat null-with-nonempty-raw as
  /// "unconfirmed", never as "no profession" — see [labelFor].
  Profession? resolve(String? stored) {
    final key = stored?.trim();
    if (key == null || key.isEmpty) return null;
    final byId = _byId ?? _indexOf(all);
    final hit = byId[key.toLowerCase()];
    if (hit != null) return hit;
    // Second chance: older rows may hold the DISPLAY NAME rather than the id
    // (e.g. someone typed exactly "Electrician"). Matching that to the real
    // profession is strictly better than showing it as unconfirmed.
    final lower = key.toLowerCase();
    for (final p in all) {
      if (p.name.toLowerCase() == lower) return p;
    }
    return null;
  }

  /// What to SHOW for a stored value: the canonical label when it resolves,
  /// otherwise the user's own legacy text verbatim (never a slug, never a
  /// blank). Empty in → empty out.
  String labelFor(String? stored) {
    final raw = stored?.trim() ?? '';
    if (raw.isEmpty) return '';
    return resolve(raw)?.name ?? raw;
  }

  /// True when the stored value is a real entry in the controlled vocabulary.
  /// This — not "is it non-empty" — is what profile completion and the
  /// become-a-provider gate check.
  bool isConfirmed(String? stored) => resolve(stored) != null;

  /// Load cache, then refresh from the server when stale. Safe to call often;
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
      if (cached != null && _professions == null) {
        _apply(jsonDecode(cached));
      }
      final fresh = DateTime.now().difference(cachedAt) < _ttl;
      if (fresh && _professions != null) return;
    } catch (e) {
      debugPrint('[PROFESSION_REGISTRY] cache read failed: $e');
    }

    try {
      final rows = await Supabase.instance.client
          .from('professions')
          .select('id, name, icon, sort, category_id')
          .eq('active', true)
          .order('sort', ascending: true);
      _apply(rows);
      await prefs?.setString(_cacheKey, jsonEncode(rows));
      await prefs?.setInt(_cacheAtKey, DateTime.now().millisecondsSinceEpoch);
      debugPrint('[PROFESSION_REGISTRY] loaded ${rows.length} professions from server');
    } catch (e) {
      // Table missing (086 not applied yet), offline, etc. — the cached or
      // bundled list stays in effect and the selector works normally.
      debugPrint(
        '[PROFESSION_REGISTRY] fetch failed '
        '(using ${_professions == null ? 'bundled list' : 'cache'}): $e',
      );
    }
  }

  void _apply(dynamic rows) {
    if (rows is! List || rows.isEmpty) return;
    final parsed = <Profession>[];
    for (final row in rows) {
      final p = Profession.tryParse(row);
      if (p != null) parsed.add(p);
    }
    if (parsed.isEmpty) return;
    parsed.sort((a, b) => a.sort.compareTo(b.sort));
    _professions = parsed;
    _byId = _indexOf(parsed);
  }

  static Map<String, Profession> _indexOf(List<Profession> list) => {
        for (final p in list) p.id.toLowerCase(): p,
      };

  /// Test seam: reset to the bundled list.
  @visibleForTesting
  void resetForTest() {
    _professions = null;
    _byId = null;
    _inflight = null;
  }

  /// Test seam: install a known list without touching the network or prefs.
  @visibleForTesting
  void seedForTest(List<Profession> list) {
    _professions = List.of(list)..sort((a, b) => a.sort.compareTo(b.sort));
    _byId = _indexOf(_professions!);
  }
}
