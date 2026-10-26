import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/feed_pager.dart';
import 'package:help24/services/feed_service.dart';
import 'package:help24/services/post_service.dart';

/// Regression suite: DISCOVER SHOWED TWENTY POSTS AND STOPPED.
///
/// Measured against production on 2026-10-26: 40 open listings in the table,
/// `candidate_count: 40` from the engine, `has_more: true` on page 0 — and 20
/// cards on screen, because nothing on the device ever asked for page 1.
/// Publishing a 41st listing pushed the 20th off the end, which is how it was
/// noticed.
///
/// Paging the engine is not enough on its own: it ranks a bounded window (400
/// by default). These tests pin the property that matters — walking the feed
/// to the end yields EVERY eligible post EXACTLY once — for small corpora, for
/// corpora far larger than the ranked window, for an engine that dies
/// mid-scroll, for a ranking clock that moves between pages, and for bulk
/// inserts that share one `created_at`.

/// An in-memory marketplace with the two read paths the device uses.
class _Corpus {
  /// Newest first by (createdAt, id) — the keyset the tail walks.
  final List<FeedKey> keys;

  /// How many posts the engine considers (its `maxCandidates`).
  final int rankedWindow;

  /// Pages of the engine's ranking that fail with [FeedPageUnavailable].
  final Set<int> failingPages;

  /// A ranking clock that moves after this page: later pages come from a
  /// different ordering of the same window.
  final int? reshuffleAfterPage;

  int rankedCalls = 0;
  int probeCalls = 0;
  int hydratedRows = 0;

  _Corpus(
    this.keys, {
    this.rankedWindow = 400,
    this.failingPages = const {},
    this.reshuffleAfterPage,
  });

  factory _Corpus.sized(int n, {int rankedWindow = 400, int sameInstantEvery = 1,
      Set<int> failingPages = const {}, int? reshuffleAfterPage}) {
    final keys = [
      for (var i = 0; i < n; i++)
        FeedKey(
          id: 'p${(n - i).toString().padLeft(8, '0')}',
          // Zero-padded so string order IS time order, as Postgres compares.
          createdAt: 't${((n - i) ~/ sameInstantEvery).toString().padLeft(8, '0')}',
        ),
    ];
    // Keep the corpus in exact (createdAt desc, id desc) order.
    keys.sort((a, b) {
      final t = b.createdAt.compareTo(a.createdAt);
      return t != 0 ? t : b.id.compareTo(a.id);
    });
    return _Corpus(keys,
        rankedWindow: rankedWindow,
        failingPages: failingPages,
        reshuffleAfterPage: reshuffleAfterPage);
  }

  /// The engine's ranking: a scrambled order over its window, so the ranked
  /// head is visibly NOT chronological (and pulls in some older posts, like the
  /// nearby/affinity pools do).
  List<String> _ranking(int seed) {
    final window = keys.length <= rankedWindow
        ? [for (final k in keys) k.id]
        : [
            // Mostly the newest, plus every 7th older post.
            for (final k in keys.take(rankedWindow * 3 ~/ 4)) k.id,
            for (var i = rankedWindow * 3 ~/ 4; i < keys.length; i += 7) keys[i].id,
          ].take(rankedWindow).toList();
    final scored = [...window]..sort((a, b) =>
        ((a.hashCode ^ seed) % 1009).compareTo((b.hashCode ^ seed) % 1009));
    return scored;
  }

  Future<FeedResult<PostModel>> ranked(int page) async {
    rankedCalls++;
    if (failingPages.contains(page)) throw const FeedPageUnavailable('HTTP 503');
    final seed =
        reshuffleAfterPage != null && page > reshuffleAfterPage! ? 99 : 1;
    final order = _ranking(seed);
    const size = 20;
    final slice = order.skip(page * size).take(size).toList();
    return FeedResult<PostModel>(
      items: [for (final id in slice) _post(id)],
      source: FeedSource.ranked,
      hasMore: order.length > page * size + slice.length,
    );
  }

  Future<List<FeedKey>> probe(FeedKey? after, int limit) async {
    probeCalls++;
    var start = 0;
    if (after != null) {
      // Strictly after `after` in (createdAt desc, id desc).
      start = keys.indexWhere((k) {
        final t = k.createdAt.compareTo(after.createdAt);
        return t < 0 || (t == 0 && k.id.compareTo(after.id) < 0);
      });
      if (start < 0) return const [];
    }
    return keys.skip(start).take(limit).toList();
  }

  Future<List<PostModel>> hydrate(List<String> ids) async {
    hydratedRows += ids.length;
    return [for (final id in ids) _post(id)];
  }

  /// Walk the feed the way Discover does: first page, then next() until the
  /// cursor is spent. Returns every id shown, in order.
  Future<List<String>> walk({required FeedResult<PostModel> first}) async {
    final shown = [for (final p in first.items) p.id];
    FeedCursor? cursor = FeedCursor.after(first);
    var guard = 0;
    while (cursor != null) {
      if (++guard > 100000) fail('pager never terminated');
      final page = await FeedPager.next(
        cursor: cursor,
        seen: shown.toSet(),
        ranked: ranked,
        probe: probe,
        hydrate: hydrate,
      );
      shown.addAll(page.posts.map((p) => p.id));
      cursor = page.next;
    }
    return shown;
  }
}

PostModel _post(String id) => PostModel(
      id: id,
      title: 'Post $id',
      description: '',
      category: Category.all.last,
      location: 'Nairobi',
      price: 1000,
      urgency: Urgency.flexible,
      type: PostType.request,
      authorUserId: 'author',
    );

void _expectEveryPostExactlyOnce(List<String> shown, _Corpus corpus) {
  expect(shown.length, corpus.keys.length,
      reason: 'every eligible post must be reachable');
  expect(shown.toSet().length, shown.length, reason: 'no post may appear twice');
  expect(shown.toSet(), {for (final k in corpus.keys) k.id});
}

void main() {
  group('the production case', () {
    test('40 posts, a ranked first page of 20 — all 40 reach the screen', () async {
      final corpus = _Corpus.sized(40);
      final first = await corpus.ranked(0);
      expect(first.items, hasLength(20));
      expect(first.hasMore, isTrue, reason: 'this is the flag nothing read');

      final shown = await corpus.walk(first: first);
      _expectEveryPostExactlyOnce(shown, corpus);
    });

    test('a 41st post does not push the 20th off the end', () async {
      final corpus = _Corpus.sized(41);
      final shown = await corpus.walk(first: await corpus.ranked(0));
      _expectEveryPostExactlyOnce(shown, corpus);
    });

    test('the ranked order is kept for the head — appending never re-sorts it',
        () async {
      final corpus = _Corpus.sized(60);
      final shown = await corpus.walk(first: await corpus.ranked(0));
      final ranking = corpus._ranking(1);
      expect(shown, ranking, reason: 'whole corpus fits the window, so the '
          'feed IS the ranking, in order');
    });
  });

  group('beyond the ranked window', () {
    for (final n in [399, 400, 401, 1000, 5000, 25000]) {
      test('$n posts: every one reachable, none twice', () async {
        final corpus = _Corpus.sized(n);
        final shown = await corpus.walk(first: await corpus.ranked(0));
        _expectEveryPostExactlyOnce(shown, corpus);
      });
    }

    test('the tail costs the same at page 1000 as at page 1 (keyset, not offset)',
        () async {
      final corpus = _Corpus.sized(30000);
      final first = await corpus.ranked(0);
      await corpus.walk(first: first);
      // 30k posts in pages of 20 is ~1500 pages. Probes are 200 wide, so a
      // linear walk is ~150 probes plus the junction with the ranked head. An
      // OFFSET implementation, or one that re-probed from the top, would be
      // orders of magnitude more.
      expect(corpus.probeCalls, lessThanOrEqualTo(30000 ~/ FeedPager.probeSize + 5),
          reason: 'unserved probe rows are buffered, never re-probed');
      // Full rows are hydrated only for posts actually shown in the tail.
      expect(corpus.hydratedRows, lessThanOrEqualTo(30000));
    });
  });

  group('degradation', () {
    test('the engine dies on page 2 — the tail finishes the feed', () async {
      final corpus = _Corpus.sized(500, failingPages: {2, 3, 4, 5});
      final shown = await corpus.walk(first: await corpus.ranked(0));
      _expectEveryPostExactlyOnce(shown, corpus);
    });

    test('the first page was the chronological fallback — paging starts in the tail',
        () async {
      final corpus = _Corpus.sized(300);
      final first = FeedResult<PostModel>(
        items: [for (final k in corpus.keys.take(50)) _post(k.id)],
        source: FeedSource.fallback,
      );
      expect(FeedCursor.after(first), FeedCursor.tailStart);
      final shown = await corpus.walk(first: first);
      _expectEveryPostExactlyOnce(shown, corpus);
      expect(corpus.rankedCalls, 0, reason: 'a fallback feed has no ranked head');
    });

    test('the ranking clock moves between pages — nothing is lost, nothing repeats',
        () async {
      final corpus = _Corpus.sized(380, reshuffleAfterPage: 3);
      final shown = await corpus.walk(first: await corpus.ranked(0));
      _expectEveryPostExactlyOnce(shown, corpus);
    });
  });

  group('keyset edge cases', () {
    test('bulk inserts sharing one created_at are neither skipped nor repeated',
        () async {
      // 2000 posts, 500 to an instant — what `INSERT ... SELECT generate_series`
      // with a default now() produces, i.e. exactly a synthetic load test.
      final corpus = _Corpus.sized(2000, sameInstantEvery: 500);
      final shown = await corpus.walk(first: await corpus.ranked(0));
      _expectEveryPostExactlyOnce(shown, corpus);
    });

    test('an empty marketplace is exhausted immediately', () async {
      final corpus = _Corpus.sized(0);
      final page = await FeedPager.next(
        cursor: FeedCursor.tailStart,
        seen: const {},
        ranked: corpus.ranked,
        probe: corpus.probe,
        hydrate: corpus.hydrate,
      );
      expect(page.posts, isEmpty);
      expect(page.exhausted, isTrue);
    });

    test('a long already-seen stretch is bounded per call, and still completes',
        () async {
      final corpus = _Corpus.sized(5000);
      // The reader has somehow seen the 3000 newest (e.g. a huge ranked head).
      final seen = {for (final k in corpus.keys.take(3000)) k.id};
      final page = await FeedPager.next(
        cursor: FeedCursor.tailStart,
        seen: seen,
        ranked: corpus.ranked,
        probe: corpus.probe,
        hydrate: corpus.hydrate,
      );
      expect(corpus.probeCalls, lessThanOrEqualTo(FeedPager.maxSteps));
      expect(page.exhausted, isFalse,
          reason: 'out of budget is not the end of the feed');
      expect(page.next, isNot(FeedCursor.tailStart),
          reason: 'the cursor advanced, so the next call makes progress');
    });

    test('hydration dropping a row archived mid-page loses only that row', () async {
      final corpus = _Corpus.sized(30);
      final page = await FeedPager.next(
        cursor: FeedCursor.tailStart,
        seen: const {},
        ranked: corpus.ranked,
        probe: corpus.probe,
        hydrate: (ids) async =>
            [for (final id in ids.skip(1)) _post(id)], // first one vanished
      );
      expect(page.posts, hasLength(FeedPager.pageSize - 1));
    });
  });
}
