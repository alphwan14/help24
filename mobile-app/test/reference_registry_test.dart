import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/place.dart';
import 'package:help24/models/profession.dart';
import 'package:help24/services/location_registry.dart';
import 'package:help24/services/profession_registry.dart';
import 'package:help24/services/reference_registry.dart';

/// Tests over the SHIPPED datasets, not fixtures.
///
/// The bundled JSON assets are the offline floor for every location and
/// profession picker, and they are also the source the SQL migrations are
/// generated from. A defect in them (a duplicate id, a dropped legacy trade, an
/// area pointing at a parent that does not exist) is a production defect in two
/// places at once, so these tests load the real files through the real asset
/// bundle rather than asserting against a hand-written sample.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ───────────────────────────── Locations ──────────────────────────────────

  group('Kenya location dataset', () {
    late Map<String, dynamic> payload;
    final registry = LocationRegistry.instance;

    setUpAll(() async {
      payload = jsonDecode(await rootBundle.loadString('assets/data/locations_ke.json'))
          as Map<String, dynamic>;
      registry.resetForTest();
      expect(registry.applyPayload(payload), isTrue,
          reason: 'the shipped asset must be loadable');
    });

    test('covers every county and every county headquarters', () {
      final counties = registry.all.map((p) => p.county).toSet();
      expect(counties.length, 47, reason: 'Kenya has 47 counties');
      final hqs = registry.all.where((p) => p.isCountyHq).toList();
      expect(hqs.length, 47);
      // Exactly one HQ per county, and it is a standalone place — never a
      // neighbourhood.
      expect(hqs.map((p) => p.county).toSet().length, 47);
      expect(hqs.every((p) => p.kind != PlaceKind.area), isTrue);
    });

    test('is materially bigger than the list it replaced', () {
      // The hardcoded KenyaLocation list held 37 entries across 17 towns.
      expect(registry.all.length, greaterThan(400));
      expect(registry.cities.length, greaterThan(250));
    });

    test('has no duplicate ids and no orphaned neighbourhoods', () {
      final ids = registry.all.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'ids must be unique');
      for (final p in registry.all.where((p) => p.kind == PlaceKind.area)) {
        expect(registry.byId(p.parentId), isNotNull,
            reason: '${p.id} points at a parent that does not exist');
        expect(p.parentName, isNotNull);
      }
    });

    test('browse order is alphabetical with section headers', () {
      final names = registry.all.map((p) => p.name.toLowerCase()).toList();
      final sorted = [...names]..sort();
      expect(names, sorted);

      final rows = registry.browseRows;
      expect(rows.where((r) => r.isHeader).length, greaterThan(20));
      // Every place row sits under the header for its own letter.
      String? current;
      for (final row in rows) {
        if (row.isHeader) {
          current = row.header;
        } else {
          expect(row.place!.sectionLetter, current);
        }
      }
    });

    test('storage label reproduces the legacy string shape exactly', () {
      // This is the backward-compatibility contract: posts.location has always
      // held "Area, City" or "City", and every filter is a substring match on
      // that string.
      expect(registry.byId('nairobi-westlands')!.storageLabel, 'Westlands, Nairobi');
      expect(registry.byId('naivasha')!.storageLabel, 'Naivasha');
      expect(registry.byId('mombasa-nyali')!.storageLabel, 'Nyali, Mombasa');
    });

    test('resolves every shape posts.location has ever held', () {
      expect(registry.resolveLabel('Westlands, Nairobi')?.id, 'nairobi-westlands');
      expect(registry.resolveLabel('Nairobi')?.id, 'nairobi');
      expect(registry.resolveLabel('  nairobi  ')?.id, 'nairobi');
      // The old list generated fake "Town Centre" areas; the city half of those
      // legacy rows must still resolve.
      expect(registry.resolveLabel('Town Centre, Voi')?.id, 'voi');
      expect(registry.resolveLabel('Town Centre, Naivasha')?.id, 'naivasha');
      // Free text that matches nothing resolves to null — callers display it
      // verbatim rather than dropping the user's own words.
      expect(registry.resolveLabel('Somewhere Else'), isNull);
      expect(registry.resolveLabel(''), isNull);
      expect(registry.resolveLabel(null), isNull);
    });

    test('search is prefix-first and weight-ordered', () {
      expect(registry.search('nairobi').first.id, 'nairobi');
      // "na" must lead with the big towns, not the first alphabetical match.
      final na = registry.search('na').take(4).map((p) => p.id).toList();
      expect(na, contains('nairobi'));
      expect(na, contains('nakuru'));
      // An exact name beats a longer name that merely starts with the query.
      expect(registry.search('kisumu').first.id, 'kisumu');
      expect(registry.search('thika').first.id, 'thika');
    });

    test('search matches aliases and survives punctuation and case', () {
      expect(registry.search('msa').first.id, 'mombasa');
      expect(registry.search('kibra').first.id, 'nairobi-kibera');
      expect(registry.search('MURANGA').first.id, 'muranga');
      expect(registry.search("murang'a").first.id, 'muranga');
      expect(registry.search('rongai').map((p) => p.id), contains('ongata-rongai'));
    });

    test('search finds substrings, not just prefixes', () {
      expect(registry.search('kuru').map((p) => p.id), contains('nakuru'));
      expect(registry.search('watamu').first.id, 'watamu');
    });

    test('unknown query returns empty rather than everything', () {
      expect(registry.search('zzzzqqq'), isEmpty);
      expect(registry.search(''), isEmpty);
    });

    test('snaps a coordinate to the nearest known town — the offline path', () {
      // Nairobi CBD.
      expect(registry.nearest(-1.2864, 36.8172)?.cityName, 'Nairobi');
      // Mombasa.
      expect(registry.nearest(-4.0435, 39.6682)?.cityName, 'Mombasa');
      // Middle of the Indian Ocean: nothing within range, and inventing an
      // answer would be worse than admitting there is none.
      expect(registry.nearest(-10.0, 55.0), isNull);
    });

    test('a neighbourhood posts with ITS OWN coordinate, not its city centre', () {
      // Kileleshwa used to ship without a coordinate and inherit Nairobi's
      // centre — a silent 3 km lie on every post placed there, and the same
      // class of defect that made a Kisauni fix resolve to Nyali. Every
      // neighbourhood now carries its own position; see
      // test/location_accuracy_test.dart for the coverage guarantee.
      final kileleshwa = registry.byId('nairobi-kileleshwa')!;
      expect(kileleshwa.hasCoordinates, isTrue);

      final selection = registry.selectionFor(kileleshwa);
      expect(selection.label, 'Kileleshwa, Nairobi');
      expect(selection.cityName, 'Nairobi');
      expect(selection.latitude, kileleshwa.latitude);
      expect(selection.longitude, kileleshwa.longitude);

      final nairobi = registry.byId('nairobi')!;
      expect(selection.latitude, isNot(nairobi.latitude));
    });

    test('a coordinate-less place still inherits its city rather than posting null', () {
      // The fallback is still load-bearing: the dataset can gain a
      // neighbourhood before it gains that neighbourhood's position, and a post
      // with no coordinate at all is invisible to proximity ranking.
      const orphan = Place(
        id: 'nairobi-brand-new-estate',
        name: 'Brand New Estate',
        kind: PlaceKind.area,
        parentId: 'nairobi',
        parentName: 'Nairobi',
        county: 'Nairobi',
      );
      final selection = registry.selectionFor(orphan);
      expect(selection.hasCoordinates, isTrue);
      expect(selection.latitude, registry.byId('nairobi')!.latitude);
    });

    test('areasOf answers for cities and is honestly empty for towns', () {
      expect(registry.areasOf('Nairobi').length, greaterThan(30));
      expect(registry.areasOf('nairobi').length, greaterThan(30));
      // Voi genuinely has no neighbourhoods in the dataset. The old list
      // invented a "Town Centre" so the (city, area) tuple could exist.
      expect(registry.areasOf('Voi'), isEmpty);
    });

    test('rejects a payload older than what is already loaded', () {
      final stale = Map<String, dynamic>.from(payload)..['version'] = 0;
      expect(registry.applyPayload(stale), isFalse);
      expect(registry.all.length, greaterThan(400),
          reason: 'a rejected payload must not clear the registry');
    });
  });

  // ──────────────────────────── Professions ─────────────────────────────────

  group('Profession catalogue', () {
    late Map<String, dynamic> payload;
    final registry = ProfessionRegistry.instance;

    setUpAll(() async {
      payload = jsonDecode(await rootBundle.loadString('assets/data/professions.json'))
          as Map<String, dynamic>;
      registry.resetForTest();
      expect(registry.applyPayload(payload), isTrue);
    });

    test('is materially bigger than the seventeen it replaced', () {
      expect(registry.all.length, greaterThan(400));
      expect(registry.categories.length, greaterThan(30));
    });

    test('keeps every id migration 086 already stored on live profiles', () {
      // These values are sitting in users.profession right now. Dropping one
      // would silently turn a completed profile into an unconfirmed one.
      const legacy = {
        'electrician': 'Electrician',
        'plumber': 'Plumber',
        'mechanic': 'Mechanic',
        'cleaner': 'Cleaner',
        'tutor': 'Tutor',
        'driver': 'Driver',
        'welder': 'Welder',
        'builder': 'Builder',
        'painter': 'Painter',
        'carpenter': 'Carpenter',
        'it-technician': 'IT Technician',
        'photographer': 'Photographer',
        'salon-beauty': 'Salon & Beauty',
        'tailor': 'Tailor',
        'cook': 'Cook',
        'moving-services': 'Moving Services',
        'other': 'Other',
      };
      legacy.forEach((id, name) {
        final resolved = registry.resolve(id);
        expect(resolved, isNotNull, reason: '$id disappeared from the catalogue');
        expect(resolved!.name, name, reason: '$id was renamed');
        expect(registry.isConfirmed(id), isTrue);
      });
    });

    test('has no duplicate ids or names, and every profession has a category', () {
      final ids = registry.all.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
      final names = registry.all.map((p) => p.name.toLowerCase()).toList();
      expect(names.toSet().length, names.length);
      final categoryIds = registry.categories.map((c) => c.id).toSet();
      for (final p in registry.all) {
        expect(categoryIds, contains(p.categoryGroupId), reason: '${p.id} has no category');
      }
    });

    test('is alphabetical inside each category', () {
      for (final category in registry.categories) {
        final names =
            registry.inCategory(category.id).map((p) => p.name.toLowerCase()).toList();
        final sorted = [...names]..sort();
        expect(names, sorted, reason: '${category.id} is not alphabetical');
      }
    });

    test('browse rows group under their category header', () {
      final rows = registry.browseRows;
      expect(rows.where((r) => r.isHeader).length, registry.categories.length);
      String? current;
      for (final row in rows) {
        if (row.isHeader) {
          current = row.category!.id;
        } else {
          expect(row.profession!.categoryGroupId, current);
        }
      }
    });

    test('legacy free text still displays verbatim rather than vanishing', () {
      expect(registry.resolve('Electrical Works'), isNull);
      expect(registry.labelFor('Electrical Works'), 'Electrical Works');
      expect(registry.isConfirmed('Electrical Works'), isFalse);
      expect(registry.labelFor(''), '');
      // A stored DISPLAY NAME from before the slug era still resolves.
      expect(registry.resolve('Electrician')?.id, 'electrician');
    });

    test('search leads with the common trade, not the alphabetical one', () {
      expect(registry.search('electric').first.id, 'electrician');
      expect(registry.search('plumb').first.id, 'plumber');
      expect(registry.search('carpen').first.id, 'carpenter');
      expect(registry.search('mason').first.id, 'mason');
    });

    test('search matches Kiswahili and local terms', () {
      expect(registry.search('fundi'), isNotEmpty);
      expect(registry.search('mama fua').map((p) => p.id), contains('laundry-attendant'));
      expect(registry.search('boda').map((p) => p.id), contains('boda-boda-rider'));
      expect(registry.search('mkulima').map((p) => p.id), contains('crop-farmer'));
      expect(registry.search('kinyozi').first.id, 'barber');
      expect(registry.search('wakili').first.id, 'advocate');
    });

    test('search matches category names and cross-cutting tags', () {
      expect(registry.search('hospitality'), isNotEmpty);
      expect(registry.search('freelance'), isNotEmpty);
    });

    test('"Other" never outranks a real trade', () {
      final results = registry.search('o');
      expect(results, isNotEmpty);
      expect(results.first.id, isNot('other'));
    });

    test('icons fall back to the category rather than a generic glyph', () {
      // A profession with its own icon keeps it.
      expect(registry.iconKeyFor(registry.resolve('electrician')!), 'electrical_services');
      // One without inherits its category's.
      final blacksmith = registry.resolve('blacksmith')!;
      expect(blacksmith.iconKey, isNull);
      expect(registry.iconKeyFor(blacksmith), 'handyman');
    });

    test('tags are inherited from the category when not set', () {
      expect(registry.tagsFor(registry.resolve('blacksmith')!), contains('bc'));
      expect(registry.tagsFor(registry.resolve('software-engineer')!), contains('wc'));
    });

    test('country-scoped rows are filtered to the active market', () {
      registry.resetForTest();
      registry.countryCode = 'KE';
      expect(
        registry.applyPayload({
          'version': 1,
          'categories': [
            {'i': 'skilled-trades', 'n': 'Skilled Trades', 'icon': 'handyman', 's': 10}
          ],
          'professions': [
            {'i': 'electrician', 'n': 'Electrician', 'g': 'skilled-trades'},
            {'i': 'ke-only', 'n': 'Kenya Only', 'g': 'skilled-trades', 'cc': 'KE'},
            {'i': 'ug-only', 'n': 'Uganda Only', 'g': 'skilled-trades', 'cc': 'UG'},
          ],
        }),
        isTrue,
      );
      expect(registry.resolve('electrician'), isNotNull, reason: 'unscoped = global');
      expect(registry.resolve('ke-only'), isNotNull);
      expect(registry.resolve('ug-only'), isNull, reason: 'other markets stay hidden');

      // Restore the real catalogue for any test that runs after this one.
      registry.resetForTest();
      registry.applyPayload(payload);
    });

    test('falls back to the in-code list before any asset loads', () {
      registry.resetForTest();
      // Nothing applied: the fallback must still resolve every 086 id, because
      // a profile chip may render in the frame before the asset arrives.
      for (final p in Profession.bundled) {
        expect(registry.resolve(p.id)?.name, p.name);
      }
      registry.applyPayload(payload);
    });
  });

  // ─────────────────────────── Shared machinery ─────────────────────────────

  group('normalizeForSearch', () {
    test('folds case, diacritics, punctuation and repeated spaces', () {
      expect(normalizeForSearch('  Murang\'a  '), 'muranga');
      expect(normalizeForSearch('MOI’S BRIDGE'), 'mois bridge');
      expect(normalizeForSearch('Elgeyo-Marakwet'), 'elgeyomarakwet');
      expect(normalizeForSearch('Nairobi   West'), 'nairobi west');
      expect(normalizeForSearch('   '), '');
    });
  });

  group('SearchIndex ranking', () {
    final entries = ['Nakuru', 'Nairobi', 'Naivasha', 'Nairobi West', 'Kanairo'];
    final index = SearchIndex<String>(
      entries,
      name: (s) => s,
      weight: (s) => s == 'Nairobi' ? 100 : 0,
    );

    test('exact match wins, then prefix, then substring', () {
      expect(index.search('nairobi').first, 'Nairobi');
      expect(index.search('nai').first, 'Nairobi');
      // "airo" appears mid-word in Kanairo and in Nairobi — both are found.
      expect(index.search('airo'), containsAll(['Nairobi', 'Kanairo']));
    });

    test('repeated queries are memoised to the same list instance', () {
      final a = index.search('nai');
      final b = index.search('nai');
      expect(identical(a, b), isTrue);
    });
  });
}
