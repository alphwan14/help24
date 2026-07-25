import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show IconData;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/profession.dart';
import '../utils/icon_keys.dart';
import 'reference_registry.dart';

/// One row of the grouped browse list: a category header or a profession.
/// Precomputed once so the picker's ListView.builder does no per-row work.
@immutable
class ProfessionRow {
  final ProfessionCategory? category;
  final Profession? profession;
  const ProfessionRow.header(ProfessionCategory value)
      : category = value,
        profession = null;
  const ProfessionRow.item(Profession value)
      : profession = value,
        category = null;

  bool get isHeader => category != null;
}

/// The controlled-vocabulary client for professions.
///
/// Source of truth is the server (`profession_categories` + `professions`,
/// migrations 086 + 089). The full catalogue also ships as a bundled JSON asset
/// so the selector is complete, grouped and searchable offline and before any
/// migration is applied — see [ReferenceRegistry] for the resolution order.
///
/// Every getter answers SYNCHRONOUSLY from whatever is loaded, and [warmUp] is
/// fire-and-forget — the profession selector must never block or spin.
class ProfessionRegistry extends ReferenceRegistry {
  ProfessionRegistry._();
  static final ProfessionRegistry instance = ProfessionRegistry._();

  /// Country filter. Rows with no country are global and always included; rows
  /// scoped to another country are excluded. The seam for the next market.
  String countryCode = 'KE';

  @override
  String get debugName => 'professions';

  @override
  String get assetPath => 'assets/data/professions.json';

  int _version = 0;
  @override
  int get loadedVersion => _version;

  List<Profession> _professions = Profession.bundled;
  List<ProfessionCategory> _categories = Profession.bundledCategories;
  Map<String, Profession> _byId = _indexOf(Profession.bundled);
  Map<String, ProfessionCategory> _categoriesById =
      _categoryIndexOf(Profession.bundledCategories);
  List<ProfessionRow>? _browseRows;
  SearchIndex<Profession>? _index;

  /// Every active profession, browse order: by category, alphabetical within.
  List<Profession> get all => _professions;

  /// Every category, ordered.
  List<ProfessionCategory> get categories => _categories;

  ProfessionCategory? categoryOf(Profession p) => _categoriesById[p.categoryGroupId];

  /// Icon for a profession: its own, else its category's. Keeps five hundred
  /// professions from needing five hundred icon keys while still letting the
  /// well-known trades keep the exact glyph they have always had.
  String? iconKeyFor(Profession p) =>
      p.iconKey ?? _categoriesById[p.categoryGroupId]?.iconKey;

  /// Resolved icon for a profession — what every UI should render.
  IconData iconFor(Profession p) => iconForKey(iconKeyFor(p));

  /// Effective tags: the profession's own, else its category's.
  List<String> tagsFor(Profession p) =>
      p.tags.isNotEmpty ? p.tags : (_categoriesById[p.categoryGroupId]?.tags ?? const []);

  /// Professions in one category, alphabetical.
  List<Profession> inCategory(String categoryId) =>
      _professions.where((p) => p.categoryGroupId == categoryId).toList();

  /// Grouped browse list with category headers. Built once per dataset.
  List<ProfessionRow> get browseRows {
    final cached = _browseRows;
    if (cached != null) return cached;
    final rows = <ProfessionRow>[];
    String? group;
    for (final p in _professions) {
      if (p.categoryGroupId != group) {
        group = p.categoryGroupId;
        final category = _categoriesById[group];
        if (category != null) rows.add(ProfessionRow.header(category));
      }
      rows.add(ProfessionRow.item(p));
    }
    return _browseRows = rows;
  }

  /// Ranked search across names, aliases and category names. Safe on every
  /// keystroke — see [SearchIndex].
  List<Profession> search(String query, {int limit = 80}) =>
      _index?.search(query, limit: limit) ?? const [];

  /// Resolve a stored `users.profession` value to a known profession.
  ///
  /// Returns null for empty values AND for legacy free text ("Electrical
  /// Works") that matches no id. Callers MUST treat null-with-nonempty-raw as
  /// "unconfirmed", never as "no profession" — see [labelFor].
  Profession? resolve(String? stored) {
    final key = stored?.trim();
    if (key == null || key.isEmpty) return null;
    final hit = _byId[key.toLowerCase()];
    if (hit != null) return hit;
    // Second chance: older rows may hold the DISPLAY NAME rather than the id
    // (e.g. someone typed exactly "Electrician"). Matching that to the real
    // profession is strictly better than showing it as unconfirmed.
    final lower = key.toLowerCase();
    for (final p in _professions) {
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

  @override
  bool applyPayload(Map<String, dynamic> payload) {
    final version = payload['version'];
    if (version is! int || version < _version) return false;
    final rawCategories = payload['categories'];
    final rawProfessions = payload['professions'] ?? payload['rows'];
    if (rawProfessions is! List || rawProfessions.isEmpty) return false;

    final categories = <ProfessionCategory>[];
    if (rawCategories is List) {
      for (final row in rawCategories) {
        final c = ProfessionCategory.tryParse(row);
        if (c != null) categories.add(c);
      }
    }
    if (categories.isEmpty) categories.addAll(Profession.bundledCategories);
    categories.sort((a, b) {
      if (a.sort != b.sort) return a.sort.compareTo(b.sort);
      return a.name.compareTo(b.name);
    });
    final categoriesById = _categoryIndexOf(categories);

    final professions = <Profession>[];
    for (final row in rawProfessions) {
      final p = Profession.tryParse(row);
      if (p == null) continue;
      // Country scoping: unscoped rows are global; scoped rows only appear in
      // their own market.
      if (p.countryCode != null && p.countryCode != countryCode) continue;
      professions.add(p);
    }
    if (professions.isEmpty) return false;

    // Browse order is (category sort, name) — NOT the legacy `sort` integer.
    // With hundreds of entries, "alphabetical inside a category" is the only
    // ordering a person can predict, and it stays correct no matter what gets
    // inserted later. `sort` survives on the model for admin overrides and for
    // the original 086 rows.
    professions.sort((a, b) {
      final ca = categoriesById[a.categoryGroupId]?.sort ?? 500;
      final cb = categoriesById[b.categoryGroupId]?.sort ?? 500;
      if (ca != cb) return ca.compareTo(cb);
      if (a.categoryGroupId != b.categoryGroupId) {
        return a.categoryGroupId.compareTo(b.categoryGroupId);
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    _version = version;
    _categories = categories;
    _categoriesById = categoriesById;
    _professions = professions;
    _byId = _indexOf(professions);
    _browseRows = null;
    _index = SearchIndex<Profession>(
      professions,
      name: (p) => p.name,
      // "Other" must never outrank a real trade on a partial match, and a
      // well-known trade should beat an obscure one on a tie.
      weight: (p) => p.id == Profession.otherId ? -1000 : p.weight,
      aliases: (p) => p.aliases.isNotEmpty ? p.aliases : tagsFor(p),
      context: (p) => [
        if (categoriesById[p.categoryGroupId] != null)
          categoriesById[p.categoryGroupId]!.name,
        ...tagsFor(p).map(_tagPhrase),
      ],
    );
    return true;
  }

  @override
  Future<Map<String, dynamic>?> fetchRemote(int haveVersion) async {
    final newer = await remoteVersionIfNewer('professions:global', haveVersion);
    if (newer == null) return null;
    try {
      final client = Supabase.instance.client;
      final professions = await client
          .from('professions')
          .select('id, name, icon, sort, group_id, category_id, aliases, tags, country_code')
          .eq('active', true)
          .timeout(const Duration(seconds: 15));
      if (professions.isEmpty) return null;
      // A missing/failed category read is survivable — the bundled categories
      // still group everything — so it is fetched separately and defensively.
      List<dynamic> categories = const [];
      try {
        categories = await client
            .from('profession_categories')
            .select('id, name, icon, sort, tags')
            .eq('active', true)
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('[$debugName] categories fetch failed, using bundled: $e');
      }
      return {
        'schema': 1,
        'version': newer,
        'categories': categories,
        'professions': professions,
      };
    } catch (e) {
      debugPrint('[$debugName] professions fetch failed: $e');
      return null;
    }
  }

  static Map<String, Profession> _indexOf(List<Profession> list) => {
        for (final p in list) p.id.toLowerCase(): p,
      };

  static Map<String, ProfessionCategory> _categoryIndexOf(
          List<ProfessionCategory> list) =>
      {for (final c in list) c.id: c};

  /// Tags are stored as two-letter codes to keep the dataset small; searching
  /// for "freelance" should still work, so they expand here.
  static String _tagPhrase(String tag) => switch (tag) {
        'wc' => 'white collar professional office',
        'bc' => 'blue collar manual hands on',
        'fl' => 'freelance gig self employed',
        'em' => 'emerging digital new tech',
        _ => tag,
      };

  /// Test seam: reset to the in-code fallback list.
  @visibleForTesting
  void resetForTest() {
    _version = 0;
    _professions = Profession.bundled;
    _categories = Profession.bundledCategories;
    _byId = _indexOf(Profession.bundled);
    _categoriesById = _categoryIndexOf(Profession.bundledCategories);
    _browseRows = null;
    _index = null;
    resetLoadState();
  }

  /// Test seam: install a known list without touching the network, prefs or
  /// the asset bundle.
  @visibleForTesting
  void seedForTest(List<Profession> list, {List<ProfessionCategory>? categories}) {
    _version = 0;
    applyPayload({
      'version': 1,
      'categories': (categories ?? Profession.bundledCategories)
          .map((c) => c.toCacheMap())
          .toList(),
      'professions': list.map((p) => p.toCacheMap()).toList(),
    });
  }
}
