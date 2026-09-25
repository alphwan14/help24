import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/filter_selection.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/filter_history_service.dart';

/// Custom-profession resolution and filter history.
///
/// The corpus values here are real: production `posts.category` holds seven
/// names outside the 32-entry registry — Cleaning, Teaching, Delivery, Cooking,
/// Nyama Choma, IT, Repair — and the registry's nearest neighbour to "Cleaning"
/// is "House Cleaning", which is a different set of posts.
void main() {
  // The registry (bundled and server list are identical: 32 rows, same names)
  // plus the names the feed has actually returned.
  const corpus = <String>[
    'Plumbing',
    'House Cleaning',
    'Catering',
    'Cleaning',
    'Nyama Choma',
    'Cooking',
    'Delivery',
    'Repair',
  ];

  group('Category.resolveFilterName — sending a spelling that can match', () {
    test('THE BUG: lowercase input resolves to the corpus spelling', () {
      // Measured against production through the same RPC the app calls:
      //   'Cleaning' → 2 posts        'cleaning' → 0 posts
      expect(Category.resolveFilterName('cleaning', corpus), 'Cleaning');
      expect(Category.resolveFilterName('CLEANING', corpus), 'Cleaning');
      expect(Category.resolveFilterName('  cLeAnInG  ', corpus), 'Cleaning');
    });

    test('every casing of a name resolves to exactly one value', () {
      final resolved = {
        for (final input in ['Cleaning', 'cleaning', 'CLEANING', 'cLeaning'])
          Category.resolveFilterName(input, corpus)
      };
      expect(resolved, {'Cleaning'});
    });

    test('a multi-word custom profession resolves too', () {
      expect(Category.resolveFilterName('nyama choma', corpus), 'Nyama Choma');
      expect(Category.resolveFilterName('NYAMA   CHOMA', corpus), 'Nyama Choma');
    });

    test('"Cleaning" and "House Cleaning" stay distinct', () {
      // They are different posts. Fuzzy-matching one onto the other would show
      // people results they did not ask for.
      expect(Category.resolveFilterName('cleaning', corpus), 'Cleaning');
      expect(Category.resolveFilterName('house cleaning', corpus), 'House Cleaning');
    });

    test('a genuinely new profession is kept, normalised, as typed', () {
      expect(
        Category.resolveFilterName('  CCTV   Installer ', corpus),
        'CCTV Installer',
      );
    });

    test('unusable input is refused rather than sent', () {
      expect(Category.resolveFilterName('ab', corpus), isNull);
      expect(Category.resolveFilterName('   ', corpus), isNull);
      expect(Category.resolveFilterName('12345', corpus), isNull);
      expect(Category.resolveFilterName('x' * 41, corpus), isNull);
    });

    test('resolution is idempotent', () {
      final once = Category.resolveFilterName('cleaning', corpus)!;
      expect(Category.resolveFilterName(once, corpus), once);
    });
  });

  group('Category.suggestFilterNames — help before the guess goes wrong', () {
    test('prefix matches come before substring matches', () {
      final s = Category.suggestFilterNames('clean', corpus);
      expect(s.first, 'Cleaning');
      expect(s, contains('House Cleaning'));
      expect(s.indexOf('Cleaning'), lessThan(s.indexOf('House Cleaning')));
    });

    test('matching ignores case', () {
      expect(Category.suggestFilterNames('NYAMA', corpus), ['Nyama Choma']);
    });

    test('an empty query suggests nothing', () {
      expect(Category.suggestFilterNames('', corpus), isEmpty);
      expect(Category.suggestFilterNames('   ', corpus), isEmpty);
    });

    test('no match suggests nothing rather than everything', () {
      expect(Category.suggestFilterNames('zzzz', corpus), isEmpty);
    });

    test('duplicates in the vocabulary are collapsed', () {
      final s = Category.suggestFilterNames(
          'clean', ['Cleaning', 'cleaning', 'CLEANING']);
      expect(s, hasLength(1));
    });

    test('the list is bounded', () {
      final many = List.generate(50, (i) => 'Cleaner $i');
      expect(Category.suggestFilterNames('cleaner', many).length, lessThanOrEqualTo(6));
    });
  });

  group('FilterHistoryService codec', () {
    const plumbing = FilterSelection(categories: {'Plumbing'});
    const cleaningMombasa =
        FilterSelection(categories: {'Cleaning'}, city: 'Mombasa');
    const urgentCheap =
        FilterSelection(urgency: Urgency.urgent, maxPrice: 500);

    test('entries round-trip newest-first', () {
      final encoded = FilterHistoryService.encode(
          [cleaningMombasa, plumbing, urgentCheap]);
      expect(FilterHistoryService.decode(encoded),
          [cleaningMombasa, plumbing, urgentCheap]);
    });

    test('a custom profession survives the round trip', () {
      const custom = FilterSelection(categories: {'Nyama Choma'});
      final restored =
          FilterHistoryService.decode(FilterHistoryService.encode([custom]));
      expect(restored.single.categories, {'Nyama Choma'});
    });

    test('duplicates written by an older build are collapsed on read', () {
      final encoded = FilterHistoryService.encode(
          [plumbing, plumbing, cleaningMombasa, plumbing]);
      expect(FilterHistoryService.decode(encoded), [plumbing, cleaningMombasa]);
    });

    test('the cap is enforced on READ as well as on write', () {
      final many = [
        for (var i = 0; i < 30; i++) FilterSelection(categories: {'Cat$i'})
      ];
      expect(
        FilterHistoryService.decode(FilterHistoryService.encode(many)).length,
        FilterHistoryService.maxEntries,
      );
    });

    test('one unreadable entry does not cost the whole list', () {
      final raw = jsonEncode([
        plumbing.toJson(),
        'not an object',
        {'categories': 'wrong shape'},
        cleaningMombasa.toJson(),
      ]);
      expect(FilterHistoryService.decode(raw), [plumbing, cleaningMombasa]);
    });

    test('corrupt JSON reads as no history, not an exception', () {
      expect(FilterHistoryService.decode('{{{'), isEmpty);
      expect(FilterHistoryService.decode(''), isEmpty);
      expect(FilterHistoryService.decode('null'), isEmpty);
    });
  });

  group('history is scoped to an account', () {
    test('two accounts read two different keys', () {
      const a = 'k4DZSMyRNRNMRpXM0SypV5v6IHo2';
      const b = 'nlAJnbHFktNTYEGPPPrBE1zu0RB2';
      expect(FilterHistoryService.keyFor(a), isNot(FilterHistoryService.keyFor(b)));
      expect(FilterHistoryService.keyFor(a), 'filter_history_v1_$a');
    });

    test('the guest bucket can never collide with a real account', () {
      const guest = 'filter_history_v1_guest';
      expect(FilterHistoryService.keyFor(''), guest);
      expect(FilterHistoryService.keyFor('   '), guest);
      // 'guest' is not a Firebase uid shape (28 chars, mixed case), so no
      // account can land on the anonymous bucket.
      expect(FilterHistoryService.keyFor('nlAJnbHFktNTYEGPPPrBE1zu0RB2'),
          isNot(guest));
    });

    test('sign-out empties the in-memory list', () {
      final service = FilterHistoryService.instance;
      service.clearForSignOut();
      expect(service.entries, isEmpty);
      expect(service.isEmpty, isTrue);
    });

    test('nothing is recorded before a bucket has been loaded', () async {
      // The window between sign-out and the viewer being re-resolved: the
      // outgoing account's last filter must not fall into the guest bucket.
      final service = FilterHistoryService.instance;
      service.clearForSignOut();
      await service.record(const FilterSelection(categories: {'Plumbing'}));
      expect(service.entries, isEmpty);
    });
  });

  group('wiring (source guards)', () {
    String read(String path) => File(path).readAsStringSync();

    test('history is recorded on apply, not on open', () {
      final provider = read('lib/providers/app_provider.dart');
      final start = provider.indexOf('Future<bool> applyFilterSelection');
      final body = provider.substring(start, start + 2000);
      expect(body.contains('FilterHistoryService.instance.record(selection)'), isTrue);

      final sheet = read('lib/widgets/filter_bottom_sheet.dart');
      expect(sheet.contains('.record('), isFalse,
          reason: 'opening the sheet must not save or run anything');
    });

    test('an empty selection is never saved', () {
      final src = read('lib/services/filter_history_service.dart');
      final start = src.indexOf('Future<void> record(');
      final body = src.substring(start, start + 600);
      expect(body.contains('selection.isEmpty'), isTrue);
    });

    test('tapping a recent filter fills the sheet but does not search', () {
      final src = read('lib/widgets/filter_bottom_sheet.dart');
      final start = src.indexOf('for (final entry in _history)');
      final body = src.substring(start, start + 900);
      expect(body.contains('onPressed: () => _restore(entry)'), isTrue);
      expect(body.contains('Navigator.pop'), isFalse,
          reason: 'restoring must not apply — Search still applies');
    });

    test('sign-out drops the filters AND the in-memory history', () {
      final src = read('lib/providers/app_provider.dart');
      final start = src.indexOf('void resetForSignOut()');
      final body = src.substring(start, src.indexOf('Future<void> _loadInitialData', start));
      expect(body.contains('FilterHistoryService.instance.clearForSignOut()'), isTrue);
      expect(body.contains('_selectedCategories = {}'), isTrue);
      expect(body.contains('_selectedUrgency = null'), isTrue);
    });

    test('the vocabulary accumulates and is not read off the filtered page', () {
      // Caught on the S20+: with a Plumbing filter applied, `_posts` IS the
      // Plumbing page, so a vocabulary computed from it collapsed to the
      // categories the user had already chosen and "cleaning" no longer had
      // "Cleaning" to resolve onto.
      final src = read('lib/providers/app_provider.dart');
      expect(src.contains('final Set<String> _seenCategoryNames = {}'), isTrue);
      final start = src.indexOf('Set<String> get knownCategoryNames');
      final body = src.substring(start, start + 700);
      expect(body.contains('_seenCategoryNames'), isTrue);
      expect(body.contains('for (final p in _posts)'), isFalse);
      expect(body.contains('for (final j in _jobs)'), isFalse);
      // Fed from every page that arrives, not just the one on screen.
      //
      // This used to require three feeders, the second being the parallel
      // `_jobs` corpus. That corpus is gone — it was a whole second feed whose
      // only reader was the Jobs tab, which is a scope pill in Discover now —
      // so the jobs page reaches the vocabulary through `_warmOtherScopes`
      // instead, alongside requests and offers. Two call sites, three warmed
      // scopes: strictly more of the marketplace than before.
      expect(RegExp(r'_rememberCategoryNames\(').allMatches(src).length,
          greaterThanOrEqualTo(2));
      final warmStart = src.indexOf('Future<void> _warmOtherScopes()');
      expect(
        src.substring(warmStart, src.indexOf('\n  }', warmStart)),
        contains('_rememberCategoryNames('),
        reason: 'the warmed scopes are the vocabulary\'s second source now',
      );
    });

    test('history is loaded on demand, not only on a sign-in transition', () {
      // The auth listener only fires when the uid CHANGES, so a signed-out cold
      // start never announced a viewer and Recent never appeared — for exactly
      // the sessions that browse most.
      final provider = read('lib/providers/app_provider.dart');
      expect(provider.contains('Future<void> ensureFilterHistoryLoaded()'), isTrue);
      final setViewerStart = provider.indexOf('void setViewer(');
      expect(
        provider
            .substring(setViewerStart, setViewerStart + 3000)
            .contains('ensureFilterHistoryLoaded()'),
        isTrue,
      );

      final sheet = read('lib/widgets/filter_bottom_sheet.dart');
      expect(sheet.contains('provider.ensureFilterHistoryLoaded()'), isTrue,
          reason: 'the sheet must be able to load its own Recent row');
    });

    test('history is loaded before an entry is recorded onto it', () {
      // Recording onto an unloaded list would replace stored history with a
      // single entry instead of prepending to it.
      final src = read('lib/providers/app_provider.dart');
      final start = src.indexOf('Future<bool> applyFilterSelection');
      final body = src.substring(start, start + 2200);
      final loadAt = body.indexOf('ensureFilterHistoryLoaded()');
      final recordAt = body.indexOf('FilterHistoryService.instance.record(selection)');
      expect(loadAt, greaterThan(-1));
      expect(recordAt, greaterThan(loadAt),
          reason: 'record must be chained onto the load, not raced with it');
      expect(body.contains('.then((_) => FilterHistoryService.instance.record'),
          isTrue);
    });
  });
}
