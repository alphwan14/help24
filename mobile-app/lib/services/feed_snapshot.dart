import 'package:flutter/foundation.dart';

import '../models/post_model.dart';
import '../utils/feed_scope.dart';
import '../utils/proximity.dart';
import 'feed_service.dart';
import 'post_service.dart';

/// A Discover feed that has already been ranked, and is not going to change.
///
/// THE PROBLEM THIS SOLVES
/// ----------------------
/// Ranking used to be something the feed did *while you were reading it*. The
/// list was a mutable field that four different callers replaced — the startup
/// prefetch, the ranked follow-up, the late-arriving viewer identity, every GPS
/// update — and each replacement re-sorted the cards under the reader's thumb.
/// Nothing was wrong with any single reload; the bug was that a reload was
/// allowed to reach the screen at all.
///
/// A snapshot inverts that. Ranking is computed OFF-SCREEN and finished before
/// anything is presented; what the reader sees is a frozen, ordered list with an
/// identity attached. A new computation does not replace the visible feed — it
/// is offered, and the user (or an explicit refresh) decides when it lands.
///
/// The rule the whole file exists to enforce: **nothing that is on screen ever
/// moves unless the person looking at it asked for that.**
@immutable
class FeedSnapshot {
  /// The ordered, already-ranked posts. This list is what Discover renders and
  /// it is never re-sorted after construction.
  final List<PostModel> posts;

  /// Whether [posts] came from the ranking engine or the chronological
  /// fallback. A fallback snapshot is still a snapshot: it is stable, which is
  /// the property being defended here.
  final FeedSource source;

  /// The conditions this ranking was computed under. When the live conditions
  /// stop matching, the snapshot is stale — see [FeedIdentity.invalidationFrom].
  final FeedIdentity identity;

  /// When the ranking was computed, on the device clock.
  final DateTime generatedAt;

  /// The server's bucketed ranking clock, when it told us one. Two snapshots
  /// sharing an epoch were scored against the same instant, so any difference
  /// between them is a real change rather than time passing.
  final String? rankingEpoch;

  /// `postId → final score`. Empty on the fallback path. Diagnostic only.
  final Map<String, double> scores;

  /// `postId → per-signal breakdown`. Empty on the fallback path. Diagnostic
  /// only — no layout may depend on it.
  final Map<String, List<FeedSignalBreakdown>> signals;

  /// Whether the server had enough about this viewer to personalise.
  final bool personalised;

  /// Frozen on the way in, on EVERY path.
  ///
  /// The unmodifiable copy is not defensive-programming habit: `_install` hands
  /// the provider a working list that local splices mutate, and if that list
  /// were the snapshot's own then an optimistic insert would silently rewrite
  /// the ranking of record — which is how "the order never changes" would
  /// become false without anything looking wrong at the call site.
  factory FeedSnapshot({
    required List<PostModel> posts,
    required FeedSource source,
    required FeedIdentity identity,
    required DateTime generatedAt,
    String? rankingEpoch,
    Map<String, double> scores = const {},
    Map<String, List<FeedSignalBreakdown>> signals = const {},
    bool personalised = false,
  }) =>
      FeedSnapshot._(
        posts: List.unmodifiable(posts),
        source: source,
        identity: identity,
        generatedAt: generatedAt,
        rankingEpoch: rankingEpoch,
        scores: scores,
        signals: signals,
        personalised: personalised,
      );

  const FeedSnapshot._({
    required this.posts,
    required this.source,
    required this.identity,
    required this.generatedAt,
    this.rankingEpoch,
    this.scores = const {},
    this.signals = const {},
    this.personalised = false,
  });

  /// Build a snapshot from a freshly fetched page.
  factory FeedSnapshot.fromResult(
    FeedResult<PostModel> result, {
    required FeedIdentity identity,
    required DateTime generatedAt,
  }) =>
      FeedSnapshot(
        posts: result.items,
        source: result.source,
        identity: identity,
        generatedAt: generatedAt,
        rankingEpoch: result.rankingEpoch,
        scores: result.scores,
        signals: result.signals,
        personalised: result.personalised,
      );

  bool get isRanked => source == FeedSource.ranked;
  bool get isEmpty => posts.isEmpty;

  /// The ordering, as ids. This — not the post objects — is what "did the feed
  /// change?" means: a post whose applicant count ticked up is the same feed.
  List<String> get orderedPostIds => [for (final p in posts) p.id];

  /// How long a snapshot may be reused before a background rebuild is due.
  ///
  /// Ten minutes matches the server's ranking bucket, so a rebuild can actually
  /// produce a different answer. Refreshing faster than the engine's own clock
  /// would burn a request to be told the same thing.
  static const Duration ttl = Duration(minutes: 10);

  bool isExpiredAt(DateTime now) => now.difference(generatedAt) >= ttl;

  /// Whether [other] would visibly change this feed.
  ///
  /// Compares the **head** of the list, because that is the only part anyone is
  /// looking at when the question gets asked. A rebuild that reorders position
  /// 40 is not something to interrupt a reader for; a rebuild that changes
  /// what is under their thumb is.
  bool differsVisiblyFrom(FeedSnapshot other, {int head = 10}) {
    final a = orderedPostIds;
    final b = other.orderedPostIds;
    final n = head < a.length ? head : a.length;
    final m = head < b.length ? head : b.length;
    if (n != m) return true;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return true;
    }
    return false;
  }

  /// Ids present in [this] that were not in [previous] — "how many new posts
  /// are waiting", for the prompt's copy.
  int newPostCountSince(FeedSnapshot previous) {
    final seen = previous.orderedPostIds.toSet();
    var count = 0;
    for (final id in orderedPostIds) {
      if (!seen.contains(id)) count++;
    }
    return count;
  }

  /// Same ranking, different post objects — used when a card's own state
  /// changes (applied, archived, an optimistic insert) and the ORDER must
  /// survive it untouched.
  FeedSnapshot withPosts(List<PostModel> next) => FeedSnapshot(
        posts: next,
        source: source,
        identity: identity,
        generatedAt: generatedAt,
        rankingEpoch: rankingEpoch,
        scores: scores,
        signals: signals,
        personalised: personalised,
      );
}

/// Why a snapshot stopped being valid. Each value is a DIFFERENT decision about
/// whether the user should see the rebuild land, which is the only reason to
/// distinguish them.
enum FeedInvalidation {
  /// Nothing changed. Reuse the snapshot; issue no request.
  none,

  /// The signed-in account changed. The old feed belongs to someone else —
  /// replace it immediately, no prompt.
  viewer,

  /// The user explicitly asked (pull-to-refresh, Retry, the prompt itself).
  /// Replace immediately: they are watching for it.
  explicit,

  /// Filters, search or tab changed. The visible list is answering a question
  /// nobody is asking any more — replace immediately.
  query,

  /// The user moved far enough for proximity to mean something else. Rebuild
  /// quietly and OFFER the result.
  location,

  /// Profession or profile changed. Rebuild quietly and offer.
  profile,

  /// The user published a listing. Their own post is already at the top of the
  /// visible feed as an optimistic insert, and the engine demotes own posts —
  /// so rebuilding immediately would take away the thing they just made. Offer
  /// it instead.
  authored,

  /// The snapshot aged past its TTL. Rebuild quietly and offer.
  expired,

  /// A new release changed what ranking means. Replace immediately — reusing a
  /// snapshot computed by different rules would be a lie.
  version;

  /// Whether this reason justifies moving cards that are already on screen.
  ///
  /// The four that do are all consequences of something the user just did. The
  /// three that don't are the app noticing something on its own — and the app
  /// noticing something is never a licence to reorganise someone's screen.
  bool get replacesVisibleFeed =>
      this == FeedInvalidation.viewer ||
      this == FeedInvalidation.explicit ||
      this == FeedInvalidation.query ||
      this == FeedInvalidation.version;

  bool get isNone => this == FeedInvalidation.none;
}

/// The conditions a ranking was computed under — the snapshot's cache key.
///
/// Everything here is an input the engine actually reads. If two identities are
/// equivalent, the same ranking is still the right answer and asking the server
/// again would return what we already have.
@immutable
class FeedIdentity {
  /// Bump when a release changes what ranking MEANS (new signal, reweighted
  /// model, different scope semantics). Snapshots from an older version are
  /// discarded rather than reused, because they answer a different question.
  static const int feedVersion = 1;

  /// How far the user must move before proximity ranking could plausibly
  /// differ — and, just as importantly, how much GPS jitter is ignored.
  ///
  /// The distance signal is `1/(1+(d/15km)^1.5)`. At any realistic corpus
  /// spread, sub-kilometre movement cannot reorder a feed; it only used to,
  /// because `setViewer` compared raw doubles and treated a 3-metre drift as a
  /// new location. One kilometre is the smallest move that can genuinely change
  /// which posts are "near you".
  static const double significantMoveKm = 1.0;

  final String? userId;
  final double? latitude;
  final double? longitude;

  /// Monotonic counter bumped whenever the user's profile/profession changes.
  /// A counter rather than the profession itself: the provider does not need to
  /// know what a profession IS to know that one changed.
  final int profileRevision;

  /// Scope + every explicit filter + the search query, flattened. Explicit
  /// filters are hard constraints server-side, so a different query is a
  /// different feed, not a re-ranking of this one.
  final String queryKey;

  final int version;

  const FeedIdentity({
    this.userId,
    this.latitude,
    this.longitude,
    this.profileRevision = 0,
    this.queryKey = '',
    this.version = feedVersion,
  });

  /// The identity of a feed request, built from the state that produced it.
  factory FeedIdentity.of({
    String? userId,
    double? latitude,
    double? longitude,
    int profileRevision = 0,
    required FeedScope scope,
    required PostFilters filters,
  }) =>
      FeedIdentity(
        userId: userId,
        latitude: latitude,
        longitude: longitude,
        profileRevision: profileRevision,
        queryKey: describeQuery(scope, filters),
      );

  bool get hasCoordinates => latitude != null && longitude != null;

  /// Every explicit input the server treats as a hard constraint, in a fixed
  /// order. Categories are sorted so that selecting A then B and B then A are
  /// recognised as the same feed rather than two.
  static String describeQuery(FeedScope scope, PostFilters filters) {
    final categories = [...?filters.categories]..sort();
    return [
      scope.wire,
      filters.searchQuery?.trim().toLowerCase() ?? '',
      categories.join('|'),
      filters.city ?? '',
      filters.area ?? '',
      filters.urgency ?? '',
      filters.difficulty ?? '',
      filters.minPrice?.toStringAsFixed(0) ?? '',
      filters.maxPrice?.toStringAsFixed(0) ?? '',
    ].join('');
  }

  /// Why a snapshot built under [this] no longer answers [next].
  ///
  /// Ordered by severity: the reasons that replace the visible feed are checked
  /// first, so a tab switch that also happens to coincide with a GPS update is
  /// reported as the tab switch — which is the one the user will be expecting.
  FeedInvalidation invalidationFrom(FeedIdentity next) {
    if (version != next.version) return FeedInvalidation.version;
    if (userId != next.userId) return FeedInvalidation.viewer;
    if (queryKey != next.queryKey) return FeedInvalidation.query;
    if (profileRevision != next.profileRevision) return FeedInvalidation.profile;
    if (_movedSignificantly(next)) return FeedInvalidation.location;
    return FeedInvalidation.none;
  }

  /// Gaining or losing coordinates entirely is always significant — the
  /// distance signal switches between contributing 30 points and not
  /// participating at all. Between two known positions it is a real distance,
  /// never a raw double comparison.
  bool _movedSignificantly(FeedIdentity next) {
    if (hasCoordinates != next.hasCoordinates) return true;
    if (!hasCoordinates) return false;
    final moved = distanceKm(latitude!, longitude!, next.latitude!, next.longitude!);
    return moved >= significantMoveKm;
  }

  @override
  bool operator ==(Object other) =>
      other is FeedIdentity &&
      other.userId == userId &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.profileRevision == profileRevision &&
      other.queryKey == queryKey &&
      other.version == version;

  @override
  int get hashCode =>
      Object.hash(userId, latitude, longitude, profileRevision, queryKey, version);

  @override
  String toString() =>
      'FeedIdentity(user: $userId, at: $latitude/$longitude, rev: $profileRevision, '
      'query: "$queryKey", v$version)';
}
