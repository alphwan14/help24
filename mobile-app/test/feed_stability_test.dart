import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/feed_service.dart';
import 'package:help24/services/feed_snapshot.dart';
import 'package:help24/services/post_service.dart';
import 'package:help24/utils/feed_scope.dart';

/// Regression suite: THE DISCOVER FEED MUST NOT MOVE WHILE SOMEONE IS READING IT.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// Ranking was something the feed did while you were looking at it. Four
/// independent callers each replaced the post list wholesale, and every
/// replacement re-sorted the cards under the reader's thumb:
///
///   1. the splash prefetch painted a chronological page, then a microtask
///      immediately re-ranked it — a guaranteed reorder about a second after
///      Discover appeared, on every single cold start;
///   2. the restored session resolved after that and reloaded again;
///   3. `setViewer` compared raw doubles, so a GPS revision of three metres
///      counted as "the user moved" and cost a full Discover AND Jobs reload;
///   4. the server ranked against a free-running wall clock, so two requests
///      seconds apart legitimately disagreed about near-tied posts.
///
/// The fix is a SNAPSHOT: ranking is computed off-screen, frozen with the
/// conditions it was computed under, and only replaces what is on screen when
/// the user did something that makes a change expected. Everything else is
/// offered as "New recommendations available".
///
/// These tests pin the decision rules. The server half — a bucketed ranking
/// clock — is pinned in `backend/src/feed/ranking/regressions.spec.ts`.

PostModel _post(String id) => PostModel(
      id: id,
      title: 'Post $id',
      description: '',
      category: Category.all.last,
      location: 'Mombasa',
      price: 1000,
      urgency: Urgency.flexible,
      type: PostType.request,
    );

FeedSnapshot _snapshot(
  List<String> ids, {
  FeedIdentity? identity,
  DateTime? generatedAt,
  FeedSource source = FeedSource.ranked,
}) =>
    FeedSnapshot(
      posts: [for (final id in ids) _post(id)],
      source: source,
      identity: identity ?? const FeedIdentity(),
      generatedAt: generatedAt ?? DateTime(2026, 7, 28, 9),
    );

/// Nairobi and a point ~440 km away on the coast.
const _nairobi = (lat: -1.2921, lng: 36.8219);
const _mombasa = (lat: -4.0435, lng: 39.6682);

void main() {
  group('a snapshot is frozen', () {
    test('preserves the order it was built with', () {
      final snapshot = _snapshot(['c', 'a', 'b']);
      expect(snapshot.orderedPostIds, ['c', 'a', 'b']);
    });

    test('the post list cannot be mutated in place', () {
      final snapshot = _snapshot(['a', 'b']);
      expect(() => snapshot.posts.add(_post('c')), throwsUnsupportedError);
    });

    test('withPosts changes the contents and keeps the identity', () {
      final original = _snapshot(['a', 'b']);
      final updated = original.withPosts([_post('a'), _post('b'), _post('c')]);
      expect(updated.identity, same(original.identity));
      expect(updated.generatedAt, original.generatedAt);
      expect(updated.orderedPostIds, ['a', 'b', 'c']);
    });
  });

  group('what counts as a visible change', () {
    test('the same order is not a change', () {
      expect(
        _snapshot(['a', 'b', 'c']).differsVisiblyFrom(_snapshot(['a', 'b', 'c'])),
        isFalse,
      );
    });

    test('a swap at the top IS a change', () {
      expect(
        _snapshot(['b', 'a', 'c']).differsVisiblyFrom(_snapshot(['a', 'b', 'c'])),
        isTrue,
      );
    });

    test('a reorder beyond the head is NOT worth interrupting a reader for', () {
      final head = List.generate(10, (i) => 'p$i');
      final a = _snapshot([...head, 'x', 'y']);
      final b = _snapshot([...head, 'y', 'x']);
      expect(a.differsVisiblyFrom(b), isFalse);
    });

    test('a different length at the head is a change', () {
      expect(
        _snapshot(['a']).differsVisiblyFrom(_snapshot(['a', 'b'])),
        isTrue,
      );
    });

    test('counts genuinely new posts, so the prompt can say something true', () {
      final before = _snapshot(['a', 'b', 'c']);
      final after = _snapshot(['new1', 'a', 'new2', 'b']);
      expect(after.newPostCountSince(before), 2);
    });

    test('a pure re-ranking introduces no new posts', () {
      final before = _snapshot(['a', 'b', 'c']);
      final after = _snapshot(['c', 'b', 'a']);
      expect(after.newPostCountSince(before), 0);
    });
  });

  group('expiry', () {
    final at = DateTime(2026, 7, 28, 9);

    test('is fresh inside the TTL', () {
      final snapshot = _snapshot(['a'], generatedAt: at);
      expect(
        snapshot.isExpiredAt(at.add(FeedSnapshot.ttl - const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('is expired at the TTL', () {
      final snapshot = _snapshot(['a'], generatedAt: at);
      expect(snapshot.isExpiredAt(at.add(FeedSnapshot.ttl)), isTrue);
    });
  });

  group('identity — what invalidates a ranking', () {
    const base = FeedIdentity(userId: 'u1', latitude: -4.0, longitude: 39.7);

    test('identical conditions invalidate nothing', () {
      expect(base.invalidationFrom(base), FeedInvalidation.none);
      expect(base.invalidationFrom(base).isNone, isTrue);
    });

    test('a different account replaces the feed', () {
      final next = FeedIdentity(
        userId: 'u2',
        latitude: base.latitude,
        longitude: base.longitude,
      );
      expect(base.invalidationFrom(next), FeedInvalidation.viewer);
      expect(base.invalidationFrom(next).replacesVisibleFeed, isTrue);
    });

    test('signing out replaces the feed', () {
      final next = FeedIdentity(latitude: base.latitude, longitude: base.longitude);
      expect(base.invalidationFrom(next), FeedInvalidation.viewer);
    });

    test('a changed query replaces the feed — it answers a different question', () {
      final next = FeedIdentity(
        userId: base.userId,
        latitude: base.latitude,
        longitude: base.longitude,
        queryKey: 'plumbing',
      );
      expect(base.invalidationFrom(next), FeedInvalidation.query);
      expect(base.invalidationFrom(next).replacesVisibleFeed, isTrue);
    });

    test('a profile change rebuilds but does NOT replace', () {
      final next = FeedIdentity(
        userId: base.userId,
        latitude: base.latitude,
        longitude: base.longitude,
        profileRevision: 1,
      );
      expect(base.invalidationFrom(next), FeedInvalidation.profile);
      expect(base.invalidationFrom(next).replacesVisibleFeed, isFalse);
    });

    test('a feed-version bump replaces — old rankings answer different rules', () {
      final next = FeedIdentity(
        userId: base.userId,
        latitude: base.latitude,
        longitude: base.longitude,
        version: FeedIdentity.feedVersion + 1,
      );
      expect(base.invalidationFrom(next), FeedInvalidation.version);
      expect(base.invalidationFrom(next).replacesVisibleFeed, isTrue);
    });

    test('only explicit, viewer, query and version may move what is on screen', () {
      const mayReplace = {
        FeedInvalidation.explicit,
        FeedInvalidation.viewer,
        FeedInvalidation.query,
        FeedInvalidation.version,
      };
      for (final reason in FeedInvalidation.values) {
        expect(
          reason.replacesVisibleFeed,
          mayReplace.contains(reason),
          reason: '${reason.name} disagrees with the stability contract',
        );
      }
    });
  });

  group('location significance — the GPS-jitter bug', () {
    const at = FeedIdentity(userId: 'u1', latitude: -4.0435, longitude: 39.6682);

    FeedIdentity moved({required double lat, required double lng}) =>
        FeedIdentity(userId: 'u1', latitude: lat, longitude: lng);

    test('a few metres of drift is NOT a move', () {
      // ~11 m — the size of a routine fused-provider revision. This used to be
      // `latitude != _viewerLatitude`, i.e. a full Discover AND Jobs reload.
      final next = moved(lat: -4.0436, lng: 39.6682);
      expect(at.invalidationFrom(next), FeedInvalidation.none);
    });

    test('a hundred metres is still not a move', () {
      final next = moved(lat: -4.0444, lng: 39.6682);
      expect(at.invalidationFrom(next), FeedInvalidation.none);
    });

    test('a kilometre IS a move', () {
      final next = moved(lat: -4.0525, lng: 39.6682);
      expect(at.invalidationFrom(next), FeedInvalidation.location);
    });

    test('crossing the country is a move', () {
      final next = moved(lat: _nairobi.lat, lng: _nairobi.lng);
      expect(at.invalidationFrom(next), FeedInvalidation.location);
    });

    test('gaining coordinates is always significant', () {
      const blind = FeedIdentity(userId: 'u1');
      final located = moved(lat: _mombasa.lat, lng: _mombasa.lng);
      // The distance signal goes from not participating at all to carrying the
      // heaviest weight in the model — there is no such thing as a small
      // version of that change.
      expect(blind.invalidationFrom(located), FeedInvalidation.location);
    });

    test('losing coordinates is always significant', () {
      const blind = FeedIdentity(userId: 'u1');
      expect(at.invalidationFrom(blind), FeedInvalidation.location);
    });

    test('two viewers with no coordinates have not moved', () {
      const a = FeedIdentity(userId: 'u1');
      const b = FeedIdentity(userId: 'u1');
      expect(a.invalidationFrom(b), FeedInvalidation.none);
    });

    test('an account change outranks a simultaneous move', () {
      // Signing in while walking must read as a sign-in: that is the change the
      // user is expecting to see happen.
      final next = FeedIdentity(userId: 'u2', latitude: _nairobi.lat, longitude: _nairobi.lng);
      expect(at.invalidationFrom(next), FeedInvalidation.viewer);
    });
  });

  group('query identity', () {
    PostFilters filters({
      String? search,
      List<String>? categories,
      String? city,
      double? minPrice,
    }) =>
        PostFilters(
          searchQuery: search,
          categories: categories,
          city: city,
          minPrice: minPrice,
        );

    test('the same filters produce the same key', () {
      expect(
        FeedIdentity.describeQuery(FeedScope.all, filters(city: 'Mombasa')),
        FeedIdentity.describeQuery(FeedScope.all, filters(city: 'Mombasa')),
      );
    });

    test('category order does not create a spurious new feed', () {
      expect(
        FeedIdentity.describeQuery(
            FeedScope.all, filters(categories: ['Plumbing', 'Electrical'])),
        FeedIdentity.describeQuery(
            FeedScope.all, filters(categories: ['Electrical', 'Plumbing'])),
      );
    });

    test('search is case-insensitive and trimmed', () {
      expect(
        FeedIdentity.describeQuery(FeedScope.all, filters(search: '  Plumber ')),
        FeedIdentity.describeQuery(FeedScope.all, filters(search: 'plumber')),
      );
    });

    test('a different tab is a different feed', () {
      expect(
        FeedIdentity.describeQuery(FeedScope.requests, filters()),
        isNot(FeedIdentity.describeQuery(FeedScope.offers, filters())),
      );
    });

    test('a different price floor is a different feed', () {
      expect(
        FeedIdentity.describeQuery(FeedScope.all, filters(minPrice: 500)),
        isNot(FeedIdentity.describeQuery(FeedScope.all, filters(minPrice: 900))),
      );
    });

    test('every scope is distinguishable', () {
      final keys = {
        for (final scope in FeedScope.values)
          FeedIdentity.describeQuery(scope, const PostFilters()),
      };
      expect(keys, hasLength(FeedScope.values.length));
    });
  });

  group('a fallback page is still a stable page', () {
    test('the chronological fallback produces a usable snapshot', () {
      final snapshot = _snapshot(['a', 'b'], source: FeedSource.fallback);
      expect(snapshot.isRanked, isFalse);
      expect(snapshot.orderedPostIds, ['a', 'b']);
      // Stability is the property being defended, and it does not depend on
      // ranking having been available.
      expect(snapshot.differsVisiblyFrom(_snapshot(['a', 'b'])), isFalse);
    });
  });
}
