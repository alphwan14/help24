import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/providers/app_provider.dart';
import 'package:help24/services/cache_service.dart';
import 'package:help24/services/feed_pager.dart';
import 'package:help24/services/feed_service.dart';
import 'package:help24/services/feed_snapshot.dart';
import 'package:help24/services/launch_sequence.dart';
import 'package:help24/services/post_service.dart';
import 'package:help24/utils/feed_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression suite: THE NEXT PAGE IS AN EDIT, NOT AN INSTALL.
///
/// Companion to `feed_pager_test.dart`, which proves every post is reachable.
/// This one pins how a page lands: appended below the fold without moving the
/// generation (so the list keeps the reader's scroll position and nothing
/// crossfades), never onto a feed that was replaced while it was in flight,
/// and never as a duplicate of a post spliced in meanwhile.

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

FeedSnapshot _ranked(List<String> ids, {bool hasMore = true}) =>
    FeedSnapshot.fromResult(
      FeedResult<PostModel>(
        items: [for (final id in ids) _post(id)],
        source: FeedSource.ranked,
        hasMore: hasMore,
      ),
      identity: FeedIdentity.of(scope: FeedScope.all, filters: const PostFilters()),
      generatedAt: DateTime(2026, 10, 26, 9),
    );

List<String> _ids(int from, int to) => [for (var i = from; i < to; i++) 'p$i'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppProvider provider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LaunchSequence.resetForTest();
    provider = AppProvider();
  });

  tearDown(() {
    AppProvider.debugNextPage = null;
    provider.dispose();
  });

  test('a ranked first page with has_more is pageable — the flag nothing read',
      () {
    provider.debugInstall(_ranked(_ids(0, 20)));
    expect(provider.feedHasMore, isTrue);
    expect(provider.feedExhausted, isFalse);
  });

  test('the next page is appended without moving the generation', () async {
    provider.debugInstall(_ranked(_ids(0, 20)));
    final generation = provider.feedGeneration;
    AppProvider.debugNextPage = (cursor, seen) async {
      expect(cursor.rankedPage, 1);
      expect(seen, hasLength(20));
      return FeedPage([for (final id in _ids(20, 40)) _post(id)], null);
    };

    await provider.loadMorePosts();

    expect(provider.posts.map((p) => p.id), _ids(0, 40));
    expect(provider.filteredPosts, hasLength(40));
    expect(provider.feedGeneration, generation,
        reason: 'bumping it re-keys the list and throws the reader to the top');
    expect(provider.feedHasMore, isFalse);
    expect(provider.feedExhausted, isTrue);
    expect(provider.debugInstalled!.posts, hasLength(40),
        reason: 'the ranking of record must describe what is on screen');
  });

  test('pages keep coming until the cursor is spent', () async {
    provider.debugInstall(_ranked(_ids(0, 20)));
    var served = 20;
    AppProvider.debugNextPage = (cursor, seen) async {
      final page = [for (final id in _ids(served, served + 20)) _post(id)];
      served += 20;
      return FeedPage(page, served >= 1000 ? null : FeedCursor.tailStart);
    };
    while (provider.feedHasMore) {
      await provider.loadMorePosts();
    }
    expect(provider.posts, hasLength(1000));
    expect(provider.posts.map((p) => p.id).toSet(), hasLength(1000));
  });

  test('a page for a feed replaced in flight is dropped', () async {
    provider.debugInstall(_ranked(_ids(0, 20)));
    final gate = Completer<FeedPage>();
    AppProvider.debugNextPage = (cursor, seen) => gate.future;

    final loading = provider.loadMorePosts();
    expect(provider.isLoadingMorePosts, isTrue);
    // A pull-to-refresh lands a new ranking while the page is in flight.
    provider.debugInstall(_ranked(['fresh', ..._ids(0, 19)]));
    gate.complete(FeedPage([for (final id in _ids(20, 40)) _post(id)], null));
    await loading;

    expect(provider.posts, hasLength(20));
    expect(provider.posts.first.id, 'fresh');
    expect(provider.isLoadingMorePosts, isFalse);
    expect(provider.feedHasMore, isTrue,
        reason: 'the new feed keeps its own cursor');
  });

  test('one page in flight at a time', () async {
    provider.debugInstall(_ranked(_ids(0, 20)));
    var calls = 0;
    final gate = Completer<FeedPage>();
    AppProvider.debugNextPage = (cursor, seen) {
      calls++;
      return gate.future;
    };
    final first = provider.loadMorePosts();
    // Discover asks on every scroll frame near the end.
    for (var i = 0; i < 10; i++) {
      unawaited(provider.loadMorePosts());
    }
    gate.complete(FeedPage(const [], null));
    await first;
    expect(calls, 1);
  });

  test('a failure is the footer\'s problem, not Discover\'s', () async {
    provider.debugInstall(_ranked(_ids(0, 20)));
    AppProvider.debugNextPage = (cursor, seen) async => throw Exception('offline');

    await provider.loadMorePosts();

    expect(provider.loadMorePostsFailed, isTrue);
    expect(provider.discoverError, isNull,
        reason: 'the twenty posts above the footer are still a good answer');
    expect(provider.posts, hasLength(20));
    expect(provider.feedHasMore, isTrue, reason: 'retry continues the same feed');
  });

  test('a placeholder is never paged', () async {
    provider.debugInstall(FeedSnapshot(
      posts: [for (final id in _ids(0, 20)) _post(id)],
      source: FeedSource.fallback,
      identity: FeedIdentity.of(scope: FeedScope.all, filters: const PostFilters()),
      generatedAt: DateTime(2026, 10, 26, 9),
      fromCache: true,
      cursor: FeedCursor.tailStart,
    ));
    var calls = 0;
    AppProvider.debugNextPage = (cursor, seen) async {
      calls++;
      return FeedPage(const [], null);
    };
    await provider.loadMorePosts();
    expect(calls, 0);
    expect(provider.feedHasMore, isFalse);
    expect(provider.feedExhausted, isFalse,
        reason: 'a page off the disk is not evidence the feed ended');
  });

  test('a chronological fallback first page is pageable too', () {
    provider.debugInstall(FeedSnapshot.fromResult(
      FeedResult<PostModel>(
        items: [for (final id in _ids(0, 50)) _post(id)],
        source: FeedSource.fallback,
      ),
      identity: FeedIdentity.of(scope: FeedScope.all, filters: const PostFilters()),
      generatedAt: DateTime(2026, 10, 26, 9),
    ));
    expect(provider.feedHasMore, isTrue,
        reason: 'the engine being down used to cap Discover at fifty');
    expect(provider.debugInstalled!.cursor, FeedCursor.tailStart);
  });

  test('the disk cache stays a launch placeholder, however far someone scrolled',
      () async {
    await CacheService.savePosts([for (final id in _ids(0, 3000)) _post(id)]);
    final restored = await CacheService.loadPosts();
    expect(restored, hasLength(CacheService.maxCachedPosts));
    expect(restored.first.id, 'p0');
  });
}
