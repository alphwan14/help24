/// What a browsing surface is allowed to show — the SINGLE definition, shared
/// by the ranked feed and the fallback query.
///
/// WHY THIS FILE EXISTS
/// --------------------
/// "Which posts belong in Discover" was answered in three places that did not
/// agree, so the feed's CONTENTS depended on whether the ranking backend
/// happened to be reachable:
///
///   * `fn_feed_candidates` (migration 095) selects
///     `WHERE archived_at IS NULL AND status = 'open' AND type = ANY(p_types)`;
///   * `FeedService.typesForScope` on the server maps scope `all` to
///     `['request', 'offer']`;
///   * `FeedService._withScopeType` on the client mapped scope `all` to
///     `type: null` — NO type filter — and never filtered status at all.
///
/// So when the engine was up, Discover showed open requests and offers. When it
/// fell back — a cold backend, a timeout, a 5xx — the same tab additionally
/// showed job posts (which have their own tab) and every assigned, completed,
/// disputed and cancelled listing. Users saw a feed that changed shape for
/// reasons they could not perceive, and "why is this completed job in my feed"
/// is not a question with a good answer.
///
/// The fallback exists so ranking can never be the reason Discover is empty. It
/// must not be the reason Discover is DIFFERENT.
///
/// Pure Dart — no Flutter, no network — so the mapping is unit-testable and the
/// mirror-of-the-backend claim is pinned by a test rather than by a comment.
library;

/// A browsing surface, in the vocabulary the ranking backend speaks.
///
/// [wire] is the literal `scope=` query parameter; [postTypes] mirrors
/// `FeedService.typesForScope` in backend/src/feed/feed.service.ts. The two must
/// stay identical — a drift here silently changes what the fallback shows
/// relative to the engine, which is exactly the bug this enum ends.
enum FeedScope {
  /// Discover's "All" tab. Requests and offers — NOT jobs, which have their own
  /// tab. `null` (no filter) would have been a product change disguised as a
  /// default.
  all('all', ['request', 'offer']),

  /// Discover's "Requests" tab.
  requests('requests', ['request']),

  /// Discover's "Offers" tab.
  offers('offers', ['offer']),

  /// The Jobs tab.
  jobs('jobs', ['job']);

  const FeedScope(this.wire, this.postTypes);

  /// The `scope=` query parameter value.
  final String wire;

  /// The `posts.type` values this scope admits.
  final List<String> postTypes;

  /// Discover's tab label → scope. Unknown labels fall back to [all], matching
  /// the server's `default:` branch rather than inventing a fourth behaviour.
  static FeedScope fromDiscoverFilter(String label) => switch (label) {
        'Requests' => FeedScope.requests,
        'Offers' => FeedScope.offers,
        _ => FeedScope.all,
      };
}

/// The lifecycle states a BROWSING feed shows.
///
/// Only `open`. A browsing surface exists so someone can find work they are able
/// to take, and an assigned or completed listing is not that. This mirrors
/// `fn_feed_candidates`, which has always filtered `status = 'open'`.
///
/// Deliberately NOT applied to:
///   * Saved — a shortlist must keep showing what you saved, whatever became
///     of it;
///   * My Posts — the whole point is managing your listings through their
///     lifecycle;
///   * a post already on screen — `PostCard`'s status badges and
///     `closedListingReason` still exist, because a listing can change state
///     while someone is looking at it, and that must render honestly rather
///     than vanish mid-scroll.
const List<String> kBrowsableStatuses = ['open'];
