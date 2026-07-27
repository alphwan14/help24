import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/post_service.dart';
import 'package:help24/utils/feed_scope.dart';

/// Regression suite: THE FEED'S CONTENTS MUST NOT DEPEND ON WHETHER RANKING IS UP.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// "Which posts belong in Discover" was answered in three places that disagreed:
///
///   * `fn_feed_candidates` (095) selects
///     `WHERE archived_at IS NULL AND status = 'open' AND type = ANY(p_types)`;
///   * the backend maps scope `all` → `['request', 'offer']`;
///   * the CLIENT fallback mapped scope `all` → `type: null` — no type filter —
///     and never filtered status at all.
///
/// So the same tab showed different posts depending on whether the ranking
/// backend happened to be reachable. On the fallback path Discover additionally
/// contained job posts (which have their own tab) and every assigned, completed,
/// disputed and cancelled listing. The fallback exists so ranking can never be
/// the reason Discover is EMPTY; it must not be the reason Discover is
/// DIFFERENT.
///
/// These tests pin the client half of the contract. The server half lives in
/// `backend/src/feed/feed.service.ts` (`typesForScope`) and migration 095 — the
/// mirror table below is the drift detector for both.
void main() {
  group('FeedScope mirrors the backend', () {
    /// Copied from `typesForScope` in backend/src/feed/feed.service.ts. If the
    /// server changes, this table must change with it — and this test is what
    /// makes that a failing build rather than a silent behavioural split.
    const backendTypesForScope = <String, List<String>>{
      'all': ['request', 'offer'],
      'requests': ['request'],
      'offers': ['offer'],
      'jobs': ['job'],
    };

    test('every scope maps to the same types the server maps it to', () {
      for (final scope in FeedScope.values) {
        expect(
          scope.postTypes,
          backendTypesForScope[scope.wire],
          reason: 'FeedScope.${scope.name} drifted from typesForScope',
        );
      }
    });

    test('the wire values are exactly the ones the endpoint accepts', () {
      expect(
        FeedScope.values.map((s) => s.wire).toSet(),
        backendTypesForScope.keys.toSet(),
      );
    });

    test('scope "all" is requests AND offers — not everything', () {
      // The whole bug in one assertion: `all` never meant "no filter".
      expect(FeedScope.all.postTypes, ['request', 'offer']);
      expect(FeedScope.all.postTypes, isNot(contains('job')));
    });

    test('browsable statuses mirror fn_feed_candidates', () {
      expect(kBrowsableStatuses, ['open']);
    });
  });

  group('Discover tab labels resolve to a scope', () {
    test('each tab maps to its scope', () {
      expect(FeedScope.fromDiscoverFilter('All'), FeedScope.all);
      expect(FeedScope.fromDiscoverFilter('Requests'), FeedScope.requests);
      expect(FeedScope.fromDiscoverFilter('Offers'), FeedScope.offers);
    });

    test('an unknown label falls back to all, like the server default', () {
      expect(FeedScope.fromDiscoverFilter(''), FeedScope.all);
      expect(FeedScope.fromDiscoverFilter('Nonsense'), FeedScope.all);
    });
  });

  group('PostFilters.forScope applies BOTH rules', () {
    test('scope "all" excludes jobs on the fallback query', () {
      final filters = const PostFilters().forScope(FeedScope.all);

      expect(filters.types, ['request', 'offer']);
      expect(filters.types, isNot(contains('job')));
    });

    test('scope "all" restricts to open listings', () {
      // Previously absent entirely: the fallback returned assigned, completed,
      // disputed and cancelled posts that the ranked path never shows.
      final filters = const PostFilters().forScope(FeedScope.all);

      expect(filters.statuses, ['open']);
    });

    test('every scope carries a type list and a status list', () {
      for (final scope in FeedScope.values) {
        final filters = const PostFilters().forScope(scope);
        expect(filters.types, scope.postTypes, reason: scope.name);
        expect(filters.statuses, kBrowsableStatuses, reason: scope.name);
      }
    });

    test("the user's own filters survive scoping untouched", () {
      // Scoping is a system constraint. It must never quietly drop what the
      // person actually asked for.
      final filters = const PostFilters(
        searchQuery: 'electrician',
        categories: ['Electrical'],
        city: 'Nairobi',
        area: 'Kilimani',
        urgency: 'urgent',
        minPrice: 500,
        maxPrice: 5000,
        difficulty: 'medium',
        limit: 25,
        offset: 50,
      ).forScope(FeedScope.requests);

      expect(filters.searchQuery, 'electrician');
      expect(filters.categories, ['Electrical']);
      expect(filters.city, 'Nairobi');
      expect(filters.area, 'Kilimani');
      expect(filters.urgency, 'urgent');
      expect(filters.minPrice, 500);
      expect(filters.maxPrice, 5000);
      expect(filters.difficulty, 'medium');
      expect(filters.limit, 25);
      expect(filters.offset, 50);
      // ...and the scope still applied.
      expect(filters.types, ['request']);
      expect(filters.statuses, ['open']);
    });

    test('scoping is idempotent', () {
      final once = const PostFilters().forScope(FeedScope.offers);
      final twice = once.forScope(FeedScope.offers);

      expect(twice.types, once.types);
      expect(twice.statuses, once.statuses);
    });

    test('re-scoping replaces the previous scope rather than merging it', () {
      final requests = const PostFilters().forScope(FeedScope.requests);
      final offers = requests.forScope(FeedScope.offers);

      expect(offers.types, ['offer']);
    });
  });

  group('management surfaces are deliberately NOT scoped', () {
    test('an unscoped PostFilters constrains neither type nor status', () {
      // Saved and My Posts pass filters through without forScope, because a
      // shortlist and a management screen must keep showing listings through
      // their whole lifecycle. Null here means "no filter" in PostService.
      const filters = PostFilters();

      expect(filters.types, isNull);
      expect(filters.statuses, isNull);
    });
  });
}
