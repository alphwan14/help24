import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/filter_selection.dart';
import 'package:help24/models/post_model.dart';

/// The filter set as a value — identity, price bands, and the wire contract.
///
/// Every expectation about what matches is anchored to real production data
/// (23 open unarchived posts, median price 600, maximum 4,500, seven category
/// names outside the 32-entry registry), because every one of the defects here
/// was invisible against test fixtures and obvious against the corpus.
void main() {
  group('signature — what "the same filters" means', () {
    test('category order does not change identity', () {
      const a = FilterSelection(categories: {'Plumbing', 'Painting'});
      const b = FilterSelection(categories: {'Painting', 'Plumbing'});
      expect(a.signature, b.signature);
      expect(a, b);
    });

    test('casing does not change identity', () {
      // 'Cleaning' and 'cleaning' are the SAME saved filter, even though only
      // one of them can match rows. Resolution happens before this point.
      const a = FilterSelection(categories: {'Cleaning'});
      const b = FilterSelection(categories: {'cleaning'});
      expect(a.signature, b.signature);
    });

    test('different filters have different identities', () {
      const a = FilterSelection(categories: {'Plumbing'});
      const b = FilterSelection(categories: {'Plumbing'}, city: 'Mombasa');
      const c = FilterSelection(categories: {'Plumbing'}, urgency: Urgency.urgent);
      const d = FilterSelection(categories: {'Plumbing'}, minPrice: 500, maxPrice: 1000);
      expect({a.signature, b.signature, c.signature, d.signature}, hasLength(4));
    });
  });

  group('isEmpty — the absence of a filter is not a filter', () {
    test('the default selection is empty', () {
      expect(const FilterSelection().isEmpty, isTrue);
      expect(FilterSelection.none.isEmpty, isTrue);
    });

    test('the full price range is not a price filter', () {
      const full = FilterSelection(
        minPrice: FilterSelection.priceFloor,
        maxPrice: FilterSelection.priceCeiling,
      );
      expect(full.hasPriceBound, isFalse);
      expect(full.isEmpty, isTrue);
    });

    test('any single constraint makes it non-empty', () {
      expect(const FilterSelection(categories: {'Plumbing'}).isNotEmpty, isTrue);
      expect(const FilterSelection(city: 'Mombasa').isNotEmpty, isTrue);
      expect(const FilterSelection(area: 'Kisauni').isNotEmpty, isTrue);
      expect(const FilterSelection(urgency: Urgency.urgent).isNotEmpty, isTrue);
      expect(const FilterSelection(maxPrice: 500).isNotEmpty, isTrue);
      expect(const FilterSelection(minPrice: 500).isNotEmpty, isTrue);
    });
  });

  group('price bands — sized for how Help24 is actually priced', () {
    test('every real production price is reachable', () {
      // Observed open-post prices, plus the amounts the brief named.
      for (final price in [0, 300, 500, 600, 1200, 1500, 2000, 3000, 3200, 4500]) {
        final band = PriceBand.all.firstWhere(
          (b) => !b.isAny && price >= b.min && price <= b.max,
          orElse: () => throw StateError('no band contains KES $price'),
        );
        expect(band.isAny, isFalse);
      }
    });

    test('the old slider step would have hidden the entire corpus', () {
      // 100,000 / 20 divisions = 5,000 per notch, and the dearest open post is
      // 4,500 — so one notch of the minimum handle emptied Discover.
      const oldSmallestStep = FilterSelection.priceCeiling / 20;
      const dearestOpenPost = 4500;
      expect(oldSmallestStep > dearestOpenPost, isTrue);
      // The new bands put four boundaries below that step.
      final boundariesBelow = PriceBand.all
          .where((b) => !b.isAny && b.min > 0 && b.min < oldSmallestStep)
          .length;
      expect(boundariesBelow, greaterThanOrEqualTo(3));
    });

    test('bands express max-only, min-only and both', () {
      final maxOnly = PriceBand.all.firstWhere((b) => b.label == 'Under 500');
      expect(maxOnly.min, FilterSelection.priceFloor);
      expect(maxOnly.max, lessThan(FilterSelection.priceCeiling));

      final minOnly = PriceBand.all.firstWhere((b) => b.label == 'Over 50,000');
      expect(minOnly.min, greaterThan(FilterSelection.priceFloor));
      expect(minOnly.max, FilterSelection.priceCeiling);

      final both = PriceBand.all.firstWhere((b) => b.label == '500 – 1,000');
      expect(both.min, greaterThan(FilterSelection.priceFloor));
      expect(both.max, lessThan(FilterSelection.priceCeiling));
    });

    test('bands are contiguous and ascending — no unreachable gap', () {
      final ranges = PriceBand.all.where((b) => !b.isAny).toList();
      for (var i = 1; i < ranges.length; i++) {
        expect(ranges[i].min, ranges[i - 1].max,
            reason: 'gap between ${ranges[i - 1].label} and ${ranges[i].label}');
      }
    });

    test('exactly one band is "any", and it selects nothing', () {
      expect(PriceBand.all.where((b) => b.isAny), hasLength(1));
      expect(PriceBand.forSelection(FilterSelection.none)!.isAny, isTrue);
    });

    test('a selection maps back to the band that produced it', () {
      for (final band in PriceBand.all) {
        final selection =
            FilterSelection(minPrice: band.min, maxPrice: band.max);
        expect(PriceBand.forSelection(selection), band);
      }
    });

    test('a range from an older build shows no band rather than a wrong one', () {
      const legacy = FilterSelection(minPrice: 15000, maxPrice: 35000);
      expect(PriceBand.forSelection(legacy), isNull);
    });
  });

  group('JSON round-trip — what history stores', () {
    test('a full selection survives disk', () {
      const original = FilterSelection(
        categories: {'Cleaning', 'Nyama Choma'},
        city: 'Mombasa',
        area: 'Kisauni',
        minPrice: 500,
        maxPrice: 1000,
        urgency: Urgency.soon,
      );
      final restored = FilterSelection.tryParse(original.toJson());
      expect(restored, original);
      expect(restored!.categories, original.categories);
      expect(restored.urgency, Urgency.soon);
    });

    test('an empty selection is refused — it is not a saved filter', () {
      expect(FilterSelection.tryParse(const FilterSelection().toJson()), isNull);
    });

    test('garbage is refused rather than thrown on', () {
      expect(FilterSelection.tryParse(null), isNull);
      expect(FilterSelection.tryParse('nonsense'), isNull);
      expect(FilterSelection.tryParse(<String, dynamic>{}), isNull);
      expect(FilterSelection.tryParse({'categories': 'not-a-list'}), isNull);
    });

    test('an unknown urgency degrades to no urgency, not a crash', () {
      final parsed = FilterSelection.tryParse({
        'categories': ['Plumbing'],
        'urgency': 'yesterday',
      });
      expect(parsed, isNotNull);
      expect(parsed!.urgency, isNull);
      expect(parsed.categories, {'Plumbing'});
    });

    test('out-of-range prices are clamped to the contract bounds', () {
      final parsed = FilterSelection.tryParse({
        'categories': ['Plumbing'],
        'min': -5,
        'max': 999999,
      });
      expect(parsed!.minPrice, FilterSelection.priceFloor);
      expect(parsed.maxPrice, FilterSelection.priceCeiling);
    });
  });

  group('label — what a Recent chip says', () {
    test('names the categories', () {
      expect(const FilterSelection(categories: {'Plumbing'}).label,
          contains('Plumbing'));
    });

    test('prefers the area over the city when both are set', () {
      const s = FilterSelection(city: 'Mombasa', area: 'Kisauni');
      expect(s.label, 'Kisauni');
    });

    test('reads price bounds the way the bands do', () {
      expect(const FilterSelection(maxPrice: 500).label, 'Under 500');
      expect(const FilterSelection(minPrice: 50000).label, 'Over 50k');
      expect(const FilterSelection(minPrice: 500, maxPrice: 1000).label, '500–1k');
    });
  });

  group('the client no longer asks about complexity (source guards)', () {
    String read(String path) => File(path).readAsStringSync();

    test('no difficulty parameter is sent with the feed request', () {
      final src = read('lib/providers/app_provider.dart');
      final start = src.indexOf('PostFilters get _currentFilters');
      final body = src.substring(start, start + 900);
      expect(body.contains('difficulty:'), isFalse,
          reason: 'Easy and Hard match zero rows; Any is matched literally');
    });

    test('the filter sheet offers no complexity control', () {
      final src = read('lib/widgets/filter_bottom_sheet.dart');
      expect(src.contains('Complexity REMOVED'), isTrue);
      expect(src.contains('Difficulty.values'), isFalse);
      expect(src.contains('_selectedDifficulty'), isFalse);
    });

    test('the provider holds no difficulty filter state', () {
      final src = read('lib/providers/app_provider.dart');
      expect(src.contains('_selectedDifficulty'), isFalse);
      expect(src.contains('void setDifficulty'), isFalse);
    });

    test('post and job inserts no longer assert a complexity', () {
      // The column is nullable with a server-side default, so omitting it
      // writes exactly what the client used to write — minus the claim.
      final src = read('lib/models/post_model.dart');
      expect("'difficulty': difficulty.name".allMatches(src).length, 2,
          reason: 'only the two toCacheMap round-trips may still carry it');
      for (final marker in const ["NO 'difficulty'"]) {
        expect(marker.allMatches(src).length, 2,
            reason: 'both insert payloads must document the omission');
      }
    });

    test('job cards no longer show the identical Medium badge', () {
      final src = read('lib/widgets/job_card.dart');
      expect(src.contains('difficultyText'), isFalse);
      expect(src.contains('_difficultyColor'), isFalse);
      expect(src.contains('label: job.type'), isTrue,
          reason: 'employment type replaces it — see the diagnosis');
    });
  });

  group('applying filters costs at most one request (source guards)', () {
    String read(String path) => File(path).readAsStringSync();

    test('the sheet returns its answer instead of applying itself', () {
      final src = read('lib/widgets/filter_bottom_sheet.dart');
      expect(src.contains('Navigator.pop(context, _selection)'), isTrue);
      // The old apply path: clearFilters() (which issued its OWN request with
      // empty filters) followed by five setters.
      expect(src.contains('provider.clearFilters()'), isFalse);
      expect(src.contains('provider.toggleCategory'), isFalse);
      expect(src.contains('provider.setCity'), isFalse);
    });

    test('cancelling returns nothing at all', () {
      final src = read('lib/widgets/filter_bottom_sheet.dart');
      expect(src.contains('onPressed: () => Navigator.pop(context),'), isTrue);
    });

    test('Discover does nothing when the sheet is dismissed', () {
      final src = read('lib/screens/discover_screen.dart');
      final start = src.indexOf('showModalBottomSheet<FilterSelection>');
      final body = src.substring(start - 800, start + 900);
      expect(body.contains('if (!mounted || selection == null) return;'), isTrue);
      expect(body.contains('provider.applyFilters()'), isFalse,
          reason: 'this fired a full ranked request even on cancel');
    });

    test('an unchanged selection issues no request', () {
      final src = read('lib/providers/app_provider.dart');
      final start = src.indexOf('Future<bool> applyFilterSelection');
      final body = src.substring(start, start + 1600);
      expect(body.contains('if (before == selection)'), isTrue);
      expect(body.contains('return false;'), isTrue);
    });

    test('stale responses still cannot overwrite newer filter results', () {
      // The guard that already existed and must survive this refactor.
      final src = read('lib/providers/app_provider.dart');
      expect(src.contains('final seq = ++_postsRequestSeq;'), isTrue);
      // Every point that could install a page, clear the spinner, or report a
      // failure re-checks that it still owns the request.
      expect(RegExp(r'seq != _postsRequestSeq').allMatches(src).length,
          greaterThanOrEqualTo(3));
      expect(src.contains('if (seq == _postsRequestSeq) {'), isTrue);
    });
  });
}
