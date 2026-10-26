import 'package:flutter/foundation.dart';

import '../models/post_model.dart';
import 'feed_service.dart';
import 'post_service.dart';

/// Where the next page of a Discover feed comes from.
///
/// THE BUG THIS EXISTS FOR
/// -----------------------
/// Discover showed twenty posts and stopped. The engine answers in pages of
/// twenty and says `has_more: true`; nothing on the device ever asked for page
/// two. Measured against production on 2026-10-26: 40 open listings in the
/// table, `candidate_count: 40` from the engine, 20 on screen — and publishing a
/// 41st pushed the 20th off the end, which is how it was found.
///
/// TWO HALVES, ONE FEED
/// --------------------
/// Paging the engine alone does not reach "every post". The engine ranks a
/// bounded window (`maxCandidates`, 400 by default, assembled from four pools of
/// 150), because scoring a million rows per request is not a ranking system, it
/// is a denial of service. So a feed is:
///
///   1. the **ranked head** — `GET /feed?page=n`, until the engine says it has
///      nothing more; then
///   2. the **chronological tail** — every other browsable post, newest first,
///      walked by keyset ([PostService.probeFeedKeys]) and skipping whatever the
///      head already showed.
///
/// The tail is also what makes the feed COMPLETE rather than merely long. The
/// engine's clock is bucketed to ten minutes; a reader who crosses a bucket
/// boundary between page 2 and page 3 gets page 3 of a slightly different
/// ordering, so a post can move from page 3 to page 2 and never be served. The
/// tail is a sweep of the whole corpus minus what is on screen, so a post the
/// head dropped still arrives. Every eligible post appears exactly once.
///
/// When the first page itself came from the chronological fallback (the engine
/// was down), there is no head: the cursor starts in the tail.
@immutable
class FeedCursor {
  /// The next engine page to request, or null once the ranked head is spent.
  final int? rankedPage;

  /// The last row the tail has PROBED; null means "start at the newest".
  final FeedKey? tailAfter;

  /// Rows already probed but not yet served, in feed order — everything
  /// between the last post shown and [tailAfter].
  ///
  /// A probe reads 200 keys and a page serves 20. Throwing the other 180 away
  /// made every tail page cost two round trips (probe, then hydrate); keeping
  /// them makes nine pages in ten cost one. Measured against production with
  /// 20,040 listings (2026-10-26): probe p50 320 ms, hydrate p50 310 ms — two
  /// round trips of the same size, so dropping one halves the wait at the
  /// foot of the feed.
  final List<FeedKey> buffered;

  /// The probe that filled [buffered] came back short: once it drains, the
  /// feed is over without asking again.
  final bool tailEnded;

  const FeedCursor._({
    this.rankedPage,
    this.tailAfter,
    this.buffered = const [],
    this.tailEnded = false,
  });

  /// The tail, from the top. Where a fallback feed begins its second page, and
  /// where a ranked feed goes once the engine has nothing left.
  static const FeedCursor tailStart = FeedCursor._();

  /// What follows a first page.
  factory FeedCursor.after(FeedResult<PostModel> first) =>
      first.isRanked && first.hasMore
          ? const FeedCursor._(rankedPage: 1)
          : tailStart;

  bool get inRankedHead => rankedPage != null;

  @override
  bool operator ==(Object other) =>
      other is FeedCursor &&
      other.rankedPage == rankedPage &&
      other.tailAfter == tailAfter &&
      other.tailEnded == tailEnded &&
      listEquals(other.buffered, buffered);

  @override
  int get hashCode =>
      Object.hash(rankedPage, tailAfter, tailEnded, Object.hashAll(buffered));

  @override
  String toString() => inRankedHead
      ? 'FeedCursor(ranked page $rankedPage)'
      : 'FeedCursor(tail after ${tailAfter?.id ?? 'start'}, '
          '${buffered.length} buffered${tailEnded ? ', last probe' : ''})';
}

/// One step of a feed: the posts to append and where the next step starts.
class FeedPage {
  /// New posts only — never one already in the feed.
  final List<PostModel> posts;

  /// Null when the feed is exhausted.
  final FeedCursor? next;

  const FeedPage(this.posts, this.next);

  bool get exhausted => next == null;
}

typedef RankedPageFetch = Future<FeedResult<PostModel>> Function(int page);
typedef FeedKeyProbe = Future<List<FeedKey>> Function(FeedKey? after, int limit);
typedef FeedRowHydrate = Future<List<PostModel>> Function(List<String> ids);

/// The decision of what to fetch next, as a function of the cursor and the ids
/// already on screen — so it is testable without a network or a provider.
abstract final class FeedPager {
  /// Posts per tail page, matching the engine's own page size.
  static const int pageSize = 20;

  /// Rows per keyset probe. The first tail probe after a ranked head is mostly
  /// posts the reader has seen (the head is drawn largely from the newest), so
  /// probing narrow and wide is what keeps that junction to one round trip.
  static const int probeSize = 200;

  /// Upper bound on round trips one call may spend. An all-duplicate stretch
  /// longer than this returns an empty, NOT-exhausted page with the cursor
  /// advanced; the next call carries on from there. Bounded so a pathological
  /// corpus costs a slow scroll, never a request storm.
  static const int maxSteps = 8;

  static Future<FeedPage> next({
    required FeedCursor cursor,
    required Set<String> seen,
    required RankedPageFetch ranked,
    required FeedKeyProbe probe,
    required FeedRowHydrate hydrate,
  }) async {
    var current = cursor;
    var steps = 0;

    // ── 1. the ranked head ────────────────────────────────────────────────────
    while (current.inRankedHead && steps < maxSteps) {
      steps++;
      final FeedResult<PostModel> result;
      try {
        result = await ranked(current.rankedPage!);
      } on FeedPageUnavailable catch (e) {
        // The engine went away mid-scroll (Render sleeping, a deploy, a 5xx).
        // That is not the end of the feed — the tail serves the same corpus
        // straight from the database and skips whatever is already on screen.
        debugPrint('[FEED][PAGE] ranked head unavailable ($e) — continuing in the tail');
        current = FeedCursor.tailStart;
        break;
      }
      final fresh = _unseen(result.items, seen);
      final next = result.hasMore && result.items.isNotEmpty
          ? FeedCursor._(rankedPage: current.rankedPage! + 1)
          : FeedCursor.tailStart;
      if (fresh.isNotEmpty) return FeedPage(fresh, next);
      // A page of nothing but posts already shown (the ranking clock moved
      // between pages). Keep walking rather than returning an empty page that
      // the screen would have to ask about again.
      current = next;
    }
    if (current.inRankedHead) return FeedPage(const [], current);

    // ── 2. the chronological tail ─────────────────────────────────────────────
    var after = current.tailAfter;
    var buffer = current.buffered;
    var next = 0; // read position in [buffer]
    var ended = current.tailEnded;
    final taken = <String>[];
    while (taken.length < pageSize) {
      if (next == buffer.length) {
        // A short probe already reached the end of the corpus, or this call
        // has spent its budget on rows the reader has seen.
        if (ended || steps >= maxSteps) break;
        steps++;
        buffer = await probe(after, probeSize);
        next = 0;
        if (buffer.isNotEmpty) after = buffer.last;
        if (buffer.length < probeSize) ended = true;
        continue;
      }
      final key = buffer[next++];
      // Checked as each key is SERVED, not when it was probed: the reader may
      // have been shown it since (a splice, the ranked head).
      if (!seen.contains(key.id) && !taken.contains(key.id)) taken.add(key.id);
    }

    final remaining = List<FeedKey>.unmodifiable(buffer.sublist(next));
    final exhausted = ended && remaining.isEmpty;
    final posts = _unseen(await hydrate(taken), seen);
    return FeedPage(
      posts,
      exhausted
          ? null
          : FeedCursor._(tailAfter: after, buffered: remaining, tailEnded: ended),
    );
  }

  /// [posts] minus anything in [seen], and minus repeats within itself.
  static List<PostModel> _unseen(List<PostModel> posts, Set<String> seen) {
    final ids = <String>{};
    return [
      for (final post in posts)
        if (!seen.contains(post.id) && ids.add(post.id)) post,
    ];
  }
}
