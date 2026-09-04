import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/providers/app_provider.dart';
import 'package:help24/services/feed_service.dart';
import 'package:help24/services/feed_snapshot.dart';
import 'package:help24/services/launch_sequence.dart';
import 'package:help24/services/post_service.dart';
import 'package:help24/utils/feed_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// RECOMMENDING IS HELP24'S JOB, NOT THE READER'S.
///
/// WHAT THIS REPLACED
/// ------------------
/// A "New recommendations available" pill floated over Discover whenever a
/// better ranking had been computed but not shown. It asked the user to manage
/// a system they cannot see, and the honest answer to "should I press this?"
/// was always yes — so it was a prompt with one correct response, which is not
/// a choice, it is an interruption.
///
/// The pill is gone. What is NOT gone is the reason it existed: a feed that
/// reorganises itself while somebody is reading it. That contract is unchanged
/// and is what makes silent installation safe — the ranking lands only at a
/// moment when nothing the reader is looking at can move:
///
///   * they scrolled back to the top   → [AppProvider.setFeedEngaged](false)
///   * they left Discover entirely     → [AppProvider.setDiscoverVisible](false)
///
/// Both were already the conditions under which tapping the pill was safe. What
/// was removed is the asking, not the safety — and these tests pin that.
///
/// Companions: `feed_stability_test.dart` (what counts as a visible change),
/// `feed_arrival_test.dart` (when a ranking may land at all).

PostModel _post(String id, {String author = 'someone-else'}) => PostModel(
      id: id,
      title: 'Post $id',
      description: '',
      category: Category.all.last,
      location: 'Nairobi',
      price: 1000,
      urgency: Urgency.flexible,
      type: PostType.request,
      authorUserId: author,
    );

FeedSnapshot _snapshot(List<PostModel> posts) => FeedSnapshot(
      posts: posts,
      source: FeedSource.ranked,
      identity: FeedIdentity.of(
        scope: FeedScope.all,
        filters: const PostFilters(),
      ),
      generatedAt: DateTime(2026, 9, 5, 9),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppProvider provider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LaunchSequence.resetForTest();
    provider = AppProvider();
    provider.debugSetViewerId('me');
  });

  tearDown(() => provider.dispose());

  /// Put a ranking on screen, then have a better one arrive while the reader is
  /// mid-scroll — the exact situation the pill used to announce.
  void arriveWhileReading() {
    provider.debugInstall(_snapshot([_post('a'), _post('b')]));
    provider.setFeedEngaged(true);
    provider.debugArrive(
      _snapshot([_post('new'), _post('a'), _post('b')]),
      FeedInvalidation.expired,
    );
  }

  group('a rebuild that arrives mid-scroll still waits', () {
    test('it is held, not installed under the reader', () {
      arriveWhileReading();
      expect(provider.debugPending, isNotNull,
          reason: 'installing here would move what is under their thumb');
      expect(provider.posts.first.id, 'a',
          reason: 'the visible ranking is untouched while they read');
    });

    test('scrolling further does not install it either', () async {
      arriveWhileReading();
      // Still engaged: no transition, so nothing is triggered.
      provider.setFeedEngaged(true);
      await Future<void>.delayed(Duration.zero);
      expect(provider.debugPending, isNotNull);
      expect(provider.posts.first.id, 'a');
    });
  });

  group('returning to the top installs it silently', () {
    test('the waiting ranking lands with no prompt and no tap', () async {
      arriveWhileReading();
      expect(provider.debugPending, isNotNull);

      // The reader scrolls back to the head of the list.
      provider.setFeedEngaged(false);
      await Future<void>.delayed(Duration.zero);

      expect(provider.debugPending, isNull,
          reason: 'nothing should still be waiting once it is free to land');
      expect(provider.posts.first.id, 'new',
          reason: 'the better ranking is simply on screen now');
    });

    test('a reader who scrolls away again before the microtask keeps reading',
        () async {
      arriveWhileReading();
      // Back to the top and away again within the same frame — a flick, not a
      // settle. The deferred install must notice and leave the feed alone.
      provider.setFeedEngaged(false);
      provider.setFeedEngaged(true);
      await Future<void>.delayed(Duration.zero);

      expect(provider.debugPending, isNotNull,
          reason: 'they are reading again; the swap is no longer free');
      expect(provider.posts.first.id, 'a');
    });

    test('nothing waiting means nothing happens', () async {
      provider.debugInstall(_snapshot([_post('a')]));
      final generation = provider.feedGeneration;

      provider.setFeedEngaged(true);
      provider.setFeedEngaged(false);
      await Future<void>.delayed(Duration.zero);

      expect(provider.debugPending, isNull);
      expect(provider.feedGeneration, generation,
          reason: 'no ranking changed, so the list must not be re-keyed');
    });
  });

  group('leaving Discover also cashes it in', () {
    test('a ranking waiting when the tab is left is installed', () {
      arriveWhileReading();
      expect(provider.debugPending, isNotNull);

      provider.setDiscoverVisible(false);

      expect(provider.debugPending, isNull);
      expect(provider.posts.first.id, 'new');
    });
  });

  group('the prompt is gone from the UI', () {
    // A source-shape guard, the same technique `filter_selection_test.dart`
    // uses: the behaviour above proves the ranking lands on its own, and this
    // proves nobody quietly puts the banner back to announce it.
    test('Discover no longer builds a recommendations pill', () {
      final src = File('lib/screens/discover_screen.dart').readAsStringSync();
      expect(src.contains('New recommendations available'), isFalse,
          reason: 'the banner copy must not survive anywhere in Discover');
      expect(src.contains('_buildNewRecommendationsPill'), isFalse);
    });
  });
}
