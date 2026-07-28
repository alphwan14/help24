import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/feed_service.dart';
import 'package:help24/services/feed_snapshot.dart';
import 'package:help24/services/post_service.dart';
import 'package:help24/utils/feed_scope.dart';

/// Regression suite: DISCOVER MUST NEVER TELL SOMEONE THE MARKETPLACE IS EMPTY
/// BEFORE IT HAS LOOKED.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// Opening Help24 showed, in order: "No posts found — try adjusting your
/// filters", then shimmer, then the feed. Every launch, every user, including
/// the first thing a brand-new user ever saw of the product.
///
/// It was not a rendering bug. Discover chose between three views using two
/// booleans — `isLoadingPosts && posts.isEmpty` → skeletons, `posts.isEmpty` →
/// the empty state — and those cannot express the state the app is actually in
/// at cold start: nothing loaded, nothing loading, because the first ranking
/// deliberately waits ~900 ms for the viewer identity to resolve so it can be
/// computed for the right person once. "No request in flight" was read as "the
/// request came back empty", so the empty state was reachable as a TRANSITION.
///
/// The same hole opened on every tab switch: moving to Requests re-filtered the
/// installed All page client-side, and a page that happened to hold no requests
/// rendered "No posts found" until the scoped fetch landed.
///
/// The fix is a fourth state. [FeedPresentation] names "we have not asked yet",
/// makes it the fallthrough, and makes `empty` reachable only from evidence: a
/// completed load, for the question being asked right now, that returned
/// nothing. These tests pin that rule and the two facts it rests on — what
/// counts as an answer, and what counts as the same question.
///
/// Companion suite: `feed_stability_test.dart`, which pins the rule about what
/// may MOVE once posts are on screen.

PostModel _post(String id) => PostModel(
      id: id,
      title: 'Post $id',
      description: '',
      category: Category.all.last,
      location: 'Nairobi',
      price: 1000,
      urgency: Urgency.flexible,
      type: PostType.request,
    );

FeedSnapshot _snapshot(
  List<String> ids, {
  FeedIdentity? identity,
  bool fromCache = false,
}) =>
    FeedSnapshot(
      posts: [for (final id in ids) _post(id)],
      source: fromCache ? FeedSource.fallback : FeedSource.ranked,
      identity: identity ?? const FeedIdentity(),
      generatedAt: DateTime(2026, 7, 28, 9),
      fromCache: fromCache,
    );

FeedIdentity _identity({
  String? userId,
  FeedScope scope = FeedScope.all,
  PostFilters filters = const PostFilters(),
}) =>
    FeedIdentity.of(userId: userId, scope: scope, filters: filters);

void main() {
  group('the startup state machine', () {
    test('a fresh install with nothing loaded shows skeletons, not emptiness', () {
      // The exact cold-start moment: no snapshot, no request in flight (the
      // first ranking is still waiting for the viewer identity), no error.
      expect(
        FeedPresentation.resolve(
          hasVisiblePosts: false,
          hasAnswerForCurrentQuery: false,
          isLoading: false,
          hasError: false,
        ),
        FeedPresentation.loading,
      );
    });

    test('a request in flight with nothing to show shows skeletons', () {
      expect(
        FeedPresentation.resolve(
          hasVisiblePosts: false,
          hasAnswerForCurrentQuery: false,
          isLoading: true,
          hasError: false,
        ),
        FeedPresentation.loading,
      );
    });

    test('"no posts found" requires a completed load for THIS question', () {
      expect(
        FeedPresentation.resolve(
          hasVisiblePosts: false,
          hasAnswerForCurrentQuery: true,
          isLoading: false,
          hasError: false,
        ),
        FeedPresentation.empty,
      );
    });

    test('an answer that is still being refreshed is not yet emptiness', () {
      expect(
        FeedPresentation.resolve(
          hasVisiblePosts: false,
          hasAnswerForCurrentQuery: true,
          isLoading: true,
          hasError: false,
        ),
        FeedPresentation.loading,
      );
    });

    test('a failure with nothing to show is a failure, not emptiness', () {
      // "We couldn't load this" and "there's nothing here" ask the user for
      // different things — retry versus change your filters.
      expect(
        FeedPresentation.resolve(
          hasVisiblePosts: false,
          hasAnswerForCurrentQuery: false,
          isLoading: false,
          hasError: true,
        ),
        FeedPresentation.failed,
      );
    });

    test('posts on screen outrank a loading flag', () {
      // State 2: a background refresh must never replace a readable feed with
      // shimmer.
      expect(
        FeedPresentation.resolve(
          hasVisiblePosts: true,
          hasAnswerForCurrentQuery: true,
          isLoading: true,
          hasError: false,
        ),
        FeedPresentation.content,
      );
    });

    test('posts on screen outrank a failed background rebuild', () {
      expect(
        FeedPresentation.resolve(
          hasVisiblePosts: true,
          hasAnswerForCurrentQuery: false,
          isLoading: false,
          hasError: true,
        ),
        FeedPresentation.content,
      );
    });

    test('the empty state is unreachable without an answer, whatever else is true',
        () {
      // Exhaustive over the other three facts: with no answer for the current
      // question, NO combination may produce `empty`. This is the property the
      // original bug violated.
      for (final visible in [true, false]) {
        for (final loading in [true, false]) {
          for (final error in [true, false]) {
            expect(
              FeedPresentation.resolve(
                hasVisiblePosts: visible,
                hasAnswerForCurrentQuery: false,
                isLoading: loading,
                hasError: error,
              ),
              isNot(FeedPresentation.empty),
              reason: 'visible=$visible loading=$loading error=$error',
            );
          }
        }
      }
    });
  });

  group('what counts as an answer to the question being asked', () {
    test('the same tab and filters is the same question', () {
      expect(_identity().answersSameQuestionAs(_identity()), isTrue);
    });

    test('another tab is another question — Offers says nothing about Requests',
        () {
      // The tab-switch flash: the installed All/Offers page was re-filtered
      // client-side, came up empty for Requests, and rendered "No posts found"
      // before the scoped fetch had even been issued.
      expect(
        _identity(scope: FeedScope.offers)
            .answersSameQuestionAs(_identity(scope: FeedScope.requests)),
        isFalse,
      );
      expect(
        _identity(scope: FeedScope.all)
            .answersSameQuestionAs(_identity(scope: FeedScope.requests)),
        isFalse,
      );
    });

    test('a different search is a different question', () {
      expect(
        _identity()
            .answersSameQuestionAs(_identity(
                filters: const PostFilters(searchQuery: 'electrician'))),
        isFalse,
      );
    });

    test('a different filter set is a different question', () {
      expect(
        _identity().answersSameQuestionAs(
            _identity(filters: const PostFilters(city: 'Mombasa'))),
        isFalse,
      );
    });

    test('a different account is a different question', () {
      expect(
        _identity(userId: 'a').answersSameQuestionAs(_identity(userId: 'b')),
        isFalse,
      );
    });

    test('moving does NOT change the question — only the best order', () {
      // The distinction that keeps a stale-for-ranking page usable as evidence.
      // Walking across the country changes which posts should be FIRST; it does
      // not change whether any posts exist, so a snapshot that has gone stale
      // for ranking purposes must not send Discover back to skeletons.
      const nairobi = FeedIdentity(latitude: -1.2921, longitude: 36.8219);
      const mombasa = FeedIdentity(latitude: -4.0435, longitude: 39.6682);
      expect(nairobi.answersSameQuestionAs(mombasa), isTrue);
      // ...while still being a reason to rebuild the ranking.
      expect(
        nairobi.invalidationFrom(mombasa),
        FeedInvalidation.location,
      );
    });

    test('a profile edit does NOT change the question', () {
      const before = FeedIdentity(profileRevision: 1);
      const after = FeedIdentity(profileRevision: 2);
      expect(before.answersSameQuestionAs(after), isTrue);
      expect(before.invalidationFrom(after), FeedInvalidation.profile);
    });

    test('a feed-version bump invalidates the question itself', () {
      const v1 = FeedIdentity(version: 1);
      const v2 = FeedIdentity(version: 2);
      expect(v1.answersSameQuestionAs(v2), isFalse);
    });
  });

  group('the on-disk placeholder', () {
    test('is a snapshot like any other — it renders', () {
      final placeholder = _snapshot(['a', 'b'], fromCache: true);
      expect(placeholder.posts, hasLength(2));
      expect(placeholder.fromCache, isTrue);
    });

    test('a live snapshot is not a placeholder', () {
      expect(_snapshot(['a']).fromCache, isFalse);
      expect(
        FeedSnapshot.fromResult(
          FeedResult<PostModel>(items: [_post('a')], source: FeedSource.ranked),
          identity: const FeedIdentity(),
          generatedAt: DateTime(2026, 7, 28, 9),
        ).fromCache,
        isFalse,
      );
    });

    test('stays a placeholder across an in-place edit of its posts', () {
      // withPosts is how an optimistic insert or an archive rewrites the
      // contents without touching the order. Losing the flag here would let a
      // page read off the disk start counting as evidence.
      final placeholder = _snapshot(['a'], fromCache: true);
      expect(placeholder.withPosts([_post('a'), _post('b')]).fromCache, isTrue);
    });
  });
}
