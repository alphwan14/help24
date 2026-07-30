import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/feed_service.dart';
import 'package:help24/services/feed_snapshot.dart';
import 'package:help24/services/post_service.dart';
import 'package:help24/utils/feed_scope.dart';

/// Regression suite: A RANKING MAY BE COMPUTED WHENEVER — IT MAY ONLY *LAND*
/// WHEN LANDING COSTS THE READER NOTHING.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// Computing the feed off-screen was only half the fix. A snapshot still has to
/// ARRIVE, and arriving is the moment the cards move. Two paths were allowed to
/// arrive unannounced:
///
///   * replacing the on-disk placeholder — which is right, and lands one to
///     three seconds into a launch;
///   * gaining coordinates for the first time — same window.
///
/// Both of those are exactly when someone has started to scroll, so the feed
/// still rearranged itself under a reader's thumb on a normal cold start, and
/// the reader had no way to connect it to anything they did. The users' report
/// was blunt: "the app calculates and arranges the feed while I am scrolling".
///
/// [FeedArrival] adds the missing fact — is anyone reading this right now — and
/// the companion rule: everything the app decided ON ITS OWN becomes an offer
/// above the first card. Nothing here re-ranks anything; it decides whether a
/// ranking that has already been computed is allowed to land unannounced.
///
/// The second half of the suite pins the tab-switch stand-in: Discover was
/// showing shimmer over posts it was already holding.
///
/// Companions: `feed_startup_test.dart` (what may be SAID about an empty feed)
/// and `feed_stability_test.dart` (what counts as a visible change).

PostModel _post(String id, {PostType type = PostType.request}) => PostModel(
      id: id,
      title: 'Post $id',
      description: '',
      category: Category.all.last,
      location: 'Mombasa',
      price: 1000,
      urgency: Urgency.flexible,
      type: type,
    );

FeedSnapshot _snapshot(
  List<PostModel> posts, {
  FeedIdentity? identity,
  bool fromCache = false,
}) =>
    FeedSnapshot(
      posts: posts,
      source: FeedSource.ranked,
      identity: identity ?? const FeedIdentity(),
      generatedAt: DateTime(2026, 7, 28, 9),
      fromCache: fromCache,
    );

/// The arrival decision with every fact at its calmest setting: a real ranking
/// on screen, nobody scrolling, Discover in front of the user, and a rebuild
/// that would visibly move things.
bool _installs({
  bool hasVisibleFeed = true,
  bool visibleIsPlaceholder = false,
  bool readerEngaged = false,
  bool discoverVisible = true,
  FeedInvalidation reason = FeedInvalidation.expired,
  bool gainsCoordinates = false,
  bool differsVisibly = true,
}) =>
    FeedArrival.installs(
      hasVisibleFeed: hasVisibleFeed,
      visibleIsPlaceholder: visibleIsPlaceholder,
      readerEngaged: readerEngaged,
      discoverVisible: discoverVisible,
      reason: reason,
      gainsCoordinates: gainsCoordinates,
      differsVisibly: differsVisibly,
    );

void main() {
  group('nothing lands on a reader who did not ask for it', () {
    test('the disk placeholder is NOT swapped out mid-scroll', () {
      // The cold-start case, in one line: cached posts on screen, the launch
      // ranking lands, the user is already three cards down. This used to
      // replace the list and send them back to the top.
      expect(
        _installs(visibleIsPlaceholder: true, readerEngaged: true),
        isFalse,
      );
    });

    test('...and is not swapped out at the top of the feed either', () {
      // THE LAUNCH BLINK, PINNED.
      //
      // This asserted the opposite until the placeholder rule was removed, on
      // the argument that leaving a reader on stale posts was worse than moving
      // them. It is worse — while nobody is looking. The moment somebody is, it
      // is the single most visible thing the feed does.
      //
      // The cost was concrete: when the feed request outran the launch deadline
      // (a cold ranking backend, slow mobile data — the ordinary case, not the
      // rare one) the splash handed over on the chronological stand-in, because
      // that is what a stand-in is for. The ranked page then arrived a second
      // later, landed unannounced, bumped the feed generation, and crossfaded
      // the entire list in front of somebody who had just started reading it.
      //
      // The placeholder cases that must still land are covered by rules that
      // already existed and are asserted below: during the launch there is
      // nothing on screen, a tab switch and a pull-to-refresh are the user
      // asking, and a swap on a hidden tab is unseeable.
      expect(_installs(visibleIsPlaceholder: true), isFalse);
    });

    test('a placeholder still lands when there is nothing to disturb', () {
      // Rule 1 and rule 4. This is why removing the placeholder rule does not
      // strand anyone: the disk page still fills an empty screen, and the real
      // ranking still replaces it silently on a tab nobody is looking at.
      expect(
        _installs(visibleIsPlaceholder: true, hasVisibleFeed: false),
        isTrue,
      );
      expect(
        _installs(visibleIsPlaceholder: true, discoverVisible: false),
        isTrue,
      );
    });

    test('...and when the user asked for it', () {
      // A tab switch installs its re-scoped seed and then the real scoped page;
      // a pull-to-refresh replaces the disk page it was reading. Both are the
      // user waiting for exactly this result.
      for (final reason in [FeedInvalidation.query, FeedInvalidation.explicit]) {
        expect(
          _installs(visibleIsPlaceholder: true, reason: reason),
          isTrue,
          reason: '$reason is the user asking',
        );
      }
    });

    test('a first GPS fix does not reorder a feed being read', () {
      expect(
        _installs(
          reason: FeedInvalidation.location,
          gainsCoordinates: true,
          readerEngaged: true,
        ),
        isFalse,
      );
    });

    test('an expired rebuild never lands mid-scroll', () {
      expect(_installs(reason: FeedInvalidation.expired, readerEngaged: true),
          isFalse);
    });

    test('a profile edit never lands mid-scroll', () {
      expect(_installs(reason: FeedInvalidation.profile, readerEngaged: true),
          isFalse);
    });

    test('no automatic reason survives a scrolling reader', () {
      // Exhaustive over the reasons the APP produces on its own. None of them
      // may move what someone is reading, whatever else is true.
      const automatic = [
        FeedInvalidation.location,
        FeedInvalidation.profile,
        FeedInvalidation.authored,
        FeedInvalidation.expired,
      ];
      for (final reason in automatic) {
        for (final placeholder in [true, false]) {
          for (final gains in [true, false]) {
            expect(
              _installs(
                reason: reason,
                readerEngaged: true,
                visibleIsPlaceholder: placeholder,
                gainsCoordinates: gains,
              ),
              isFalse,
              reason: '$reason placeholder=$placeholder gains=$gains',
            );
          }
        }
      }
    });
  });

  group('what the reader asked for still lands', () {
    test('every user-initiated reason replaces the feed, even mid-scroll', () {
      // These are the four the user can perceive a cause for: they tapped
      // refresh, switched tab, signed in, or installed a new version. Discover
      // returns them to the top when it lands.
      for (final reason in FeedInvalidation.values) {
        if (!reason.replacesVisibleFeed) continue;
        expect(
          _installs(reason: reason, readerEngaged: true),
          isTrue,
          reason: '$reason must replace the visible feed',
        );
      }
    });

    test('the first ranking always lands — there is nothing to disturb', () {
      expect(
        _installs(hasVisibleFeed: false, readerEngaged: true),
        isTrue,
      );
    });

    test('a rebuild that moves nothing lands silently', () {
      // Most background rebuilds return the same order. Holding one back would
      // produce a prompt that reorders nothing.
      expect(_installs(differsVisibly: false), isTrue);
    });

    test('scrolling on ANOTHER tab does not hold a rebuild back', () {
      // The engaged flag is only meaningful while Discover is the visible tab;
      // a rebuild that lands while the user reads Messages is unseeable.
      expect(
        _installs(readerEngaged: true, discoverVisible: false),
        isTrue,
      );
    });
  });

  group('a tab switch shows the posts it is already holding', () {
    final all = _snapshot([
      _post('r1'),
      _post('o1', type: PostType.offer),
      _post('r2'),
      _post('o2', type: PostType.offer),
    ]);

    test('re-scoping keeps the ranked order of the matching posts', () {
      final requests = all.rescopedFor(
        FeedScope.requests,
        FeedIdentity.of(scope: FeedScope.requests, filters: const PostFilters()),
      );
      expect(requests, isNotNull);
      expect(requests!.orderedPostIds, ['r1', 'r2']);

      final offers = all.rescopedFor(
        FeedScope.offers,
        FeedIdentity.of(scope: FeedScope.offers, filters: const PostFilters()),
      );
      expect(offers!.orderedPostIds, ['o1', 'o2']);
    });

    test('the stand-in is a PLACEHOLDER — it may never say "no posts found"',
        () {
      // This is the whole reason the seed is safe. It is a filtered view of
      // another question's answer, so it renders, it is always replaced by the
      // real scoped page, and `hasAnswerForCurrentQuery` never counts it.
      final requests = all.rescopedFor(
        FeedScope.requests,
        FeedIdentity.of(scope: FeedScope.requests, filters: const PostFilters()),
      );
      expect(requests!.fromCache, isTrue);
    });

    test('it carries the identity of the tab being opened, not the old one', () {
      final identity =
          FeedIdentity.of(scope: FeedScope.offers, filters: const PostFilters());
      final offers = all.rescopedFor(FeedScope.offers, identity);
      expect(offers!.identity.queryKey, identity.queryKey);
    });

    test('a tab with nothing in the page falls through to skeletons', () {
      // The one case where shimmer is still the honest answer: we are holding
      // nothing that belongs to this tab.
      final requestsOnly = _snapshot([_post('r1'), _post('r2')]);
      expect(
        requestsOnly.rescopedFor(
          FeedScope.offers,
          FeedIdentity.of(scope: FeedScope.offers, filters: const PostFilters()),
        ),
        isNull,
      );
    });

    test('a placeholder can be re-scoped without becoming an answer', () {
      final cached = _snapshot([_post('r1')], fromCache: true);
      final scoped = cached.rescopedFor(
        FeedScope.requests,
        FeedIdentity.of(scope: FeedScope.requests, filters: const PostFilters()),
      );
      expect(scoped!.fromCache, isTrue);
    });
  });
}
