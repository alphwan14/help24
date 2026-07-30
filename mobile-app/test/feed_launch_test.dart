import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/providers/app_provider.dart';
import 'package:help24/services/feed_service.dart';
import 'package:help24/services/feed_snapshot.dart';
import 'package:help24/services/launch_sequence.dart';
import 'package:help24/services/post_service.dart';
import 'package:help24/utils/feed_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression suite: THE LAUNCH IS ONE TRANSACTION, AND YOUR OWN POST IS NOT
/// NEWS.
///
/// TWO BUGS, ONE ROOT
/// ------------------
/// Both of the things users reported here come from the same place: the app had
/// no way to distinguish REPLACING the feed from EDITING it.
///
///   1. "It blinks and re-installs after it is already on screen." Four paths
///      could each install a ranking during the first two seconds of a launch —
///      the disk cache, the chronological stand-in, the ranked page, and the
///      viewer identity arriving from HomeScreen. Every install re-keys
///      Discover's list, which crossfades the feed and drops the scroll
///      position. Two installs is one visible blink.
///
///   2. "I post something and it tells me there are new posts." The optimistic
///      insert spliced the working list but not `_installed`, so the ranking of
///      record did not contain the author's own listing — and the next rebuild
///      therefore counted it as somebody else's new post and offered it back to
///      them.
///
/// The fixes are a latch ([LaunchSequence]) that makes launch installs
/// unseeable by construction, a split between `_install` and `_splice`, and an
/// offer rule that knows who wrote what.
///
/// Companions: `feed_arrival_test.dart` (when a ranking may land),
/// `feed_stability_test.dart` (what counts as a visible change),
/// `feed_startup_test.dart` (what may be SAID about an empty feed).

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

FeedSnapshot _snapshot(
  List<PostModel> posts, {
  FeedSource source = FeedSource.ranked,
  bool fromCache = false,
}) =>
    FeedSnapshot(
      posts: posts,
      source: source,
      identity: FeedIdentity.of(
        scope: FeedScope.all,
        filters: const PostFilters(),
      ),
      generatedAt: DateTime(2026, 7, 30, 9),
      fromCache: fromCache,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LaunchSequence.resetForTest();
  });

  group('the launch settles behind the splash', () {
    test('while the splash is up, every arrival lands — nothing is on screen',
        () {
      // Rule 2 of FeedArrival. This is what lets the disk page, the
      // chronological stand-in and the ranked page all resolve during one
      // launch while the user meets only the last of them.
      for (final reason in FeedInvalidation.values) {
        expect(
          FeedArrival.installs(
            hasVisibleFeed: true,
            launchInProgress: true,
            visibleIsPlaceholder: false,
            readerEngaged: true,
            discoverVisible: true,
            reason: reason,
            gainsCoordinates: false,
            differsVisibly: true,
          ),
          isTrue,
          reason: '$reason must be free to land while the splash holds',
        );
      }
    });

    test('once the splash lifts, an automatic rebuild is held again', () {
      // The same call with the launch over: the reader is scrolling, so the
      // ranked page that overran the deadline is offered rather than applied.
      expect(
        FeedArrival.installs(
          hasVisibleFeed: true,
          launchInProgress: false,
          visibleIsPlaceholder: false,
          readerEngaged: true,
          discoverVisible: true,
          reason: FeedInvalidation.expired,
          gainsCoordinates: false,
          differsVisibly: true,
        ),
        isFalse,
      );
    });

    test('the latch is not held before a launch begins', () {
      // Every widget test, and any code path that runs without main(). The
      // default must be "the launch is over", never "the launch is pending" —
      // the second would make arrivals free forever.
      expect(LaunchSequence.isHoldingSplash, isFalse);
    });

    test('begin() holds it, markFeedFinal() releases it', () async {
      LaunchSequence.begin();
      expect(LaunchSequence.isHoldingSplash, isTrue);

      var handedOver = false;
      unawaited(LaunchSequence.ready.then((_) => handedOver = true));
      LaunchSequence.markFeedFinal();
      await Future<void>.delayed(Duration.zero);

      expect(handedOver, isTrue);
      LaunchSequence.lift();
      expect(LaunchSequence.isHoldingSplash, isFalse);
    });

    test('markFeedFinal is idempotent — every degradation path may call it',
        () async {
      LaunchSequence.begin();
      LaunchSequence.markFeedFinal();
      LaunchSequence.markFeedFinal();
      LaunchSequence.markFeedFinal();
      await expectLater(LaunchSequence.ready, completes);
    });

    test('a launch can finish before the splash widget exists', () {
      // MEASURED ON A GALAXY A21s: the launch handed over at +3518ms and
      // StartupGate was not created until +4280ms. The deadline is armed in
      // main(), but nothing can be PAINTED until Flutter has built a tree — and
      // on a slow device that is seconds, not frames.
      //
      // StartupGate reads this synchronously at construction. Without it the
      // gate woke up, found itself closed, painted a fresh brand screen three
      // quarters of a second after the app was ready, and faded it out again —
      // which is exactly the "it loads two separate splash screens" report, and
      // why the launch looked different on different phones.
      LaunchSequence.begin();
      expect(LaunchSequence.handedOver, isFalse);

      LaunchSequence.markFeedFinal();

      expect(LaunchSequence.handedOver, isTrue,
          reason: 'a gate built after this point must not paint a splash');
    });

    test('handedOver is false on a cold class, before any launch', () {
      // Every widget test. The gate must behave as though a launch is pending
      // rather than skipping straight past a splash that was never armed.
      expect(LaunchSequence.handedOver, isFalse);
    });

    test('the deadline is a bound, not a dependency', () {
      // The whole point: nothing about a dead backend, a cold ranker or a
      // denied permission can keep the splash up.
      //
      // The ceiling is a judgement about how long a branded screen may be held
      // in front of somebody, not a technical limit. It costs nothing on a
      // healthy launch — the splash lifts the moment the feed is final — so it
      // bounds only the slow path. Past about three seconds a splash stops
      // reading as a launch and starts reading as a hang.
      expect(LaunchSequence.deadline.inMilliseconds, lessThanOrEqualTo(3000));
      expect(LaunchSequence.deadline.inMilliseconds, greaterThan(0));
    });

    test('the stand-in is only painted once the launch is nearly out of time',
        () {
      // AppProvider._rankingPatience decides when the chronological page
      // replaces the wait for a ranked one. It has to sit just SHORT of the
      // deadline: earlier than that it pre-empts a ranking that was going to
      // arrive in time, for no gain — nobody is waiting on the stand-in,
      // because the splash is still up either way. Later than the deadline and
      // it paints in front of the reader instead of behind the splash.
      const patience = Duration(milliseconds: 2600);
      expect(patience, lessThan(LaunchSequence.deadline));
      expect(
        LaunchSequence.deadline - patience,
        lessThan(const Duration(milliseconds: 800)),
        reason: 'the stand-in must land shortly before the handover, not early',
      );
    });
  });

  group('install replaces, splice edits', () {
    late AppProvider provider;

    setUp(() => provider = AppProvider());
    tearDown(() => provider.dispose());

    test('installing a ranking bumps the generation — Discover crossfades', () {
      final before = provider.feedGeneration;
      provider.debugInstall(_snapshot([_post('a'), _post('b')]));
      expect(provider.feedGeneration, before + 1);
    });

    test('installing an IDENTICAL ranking does not re-key the list', () {
      // THE LAUNCH BLINK, TAKEN FROM A DEVICE TRACE.
      //
      //   +1050ms  gen=1  fallback  placeholder=true   19 posts  (disk cache)
      //   +3046ms  splash hands over — the ranking has not arrived
      //   +4850ms  gen=2  ranked    placeholder=false  19 posts
      //
      // The nineteen posts were THE SAME NINETEEN IN THE SAME ORDER, because
      // the disk cache is written from the previous session's ranked page. So
      // FeedArrival let it install, exactly as designed: it moved nothing. And
      // then the generation bumped, Discover re-keyed its list, and the whole
      // feed crossfaded. A blink carrying no information at all.
      //
      // The generation now means "what the reader is looking at changed", and
      // uses the same predicate FeedArrival does — so a rebuild admitted
      // BECAUSE it moves nothing can no longer move anything.
      provider.debugInstall(_snapshot([_post('a'), _post('b'), _post('c')]));
      final settled = provider.feedGeneration;

      provider.debugInstall(_snapshot([_post('a'), _post('b'), _post('c')]));

      expect(provider.feedGeneration, settled);
      expect(provider.debugInstalled!.isRanked, isTrue,
          reason: 'the newer snapshot is still adopted — only the key is stable');
    });

    test('a placeholder replaced by an identical ranking is silent', () {
      // The device trace above, end to end: the disk page hands over, the real
      // ranking lands, and nothing whatsoever moves.
      provider.debugInstall(_snapshot(
        [_post('a'), _post('b')],
        source: FeedSource.fallback,
        fromCache: true,
      ));
      final settled = provider.feedGeneration;

      provider.debugArrive(
        _snapshot([_post('a'), _post('b')]),
        FeedInvalidation.expired,
      );

      expect(provider.feedGeneration, settled);
      expect(provider.hasPendingFeed, isFalse,
          reason: 'nothing to offer either — it is the same feed');
      expect(provider.debugInstalled!.fromCache, isFalse,
          reason: 'the real ranking is now the page of record');
    });

    test('a reordered ranking DOES re-key — that crossfade is earned', () {
      provider.debugInstall(_snapshot([_post('a'), _post('b')]));
      final settled = provider.feedGeneration;
      provider.debugInstall(_snapshot([_post('b'), _post('a')]));
      expect(provider.feedGeneration, settled + 1);
    });

    test('an optimistic insert does NOT bump it — the list keeps its place', () {
      provider.debugInstall(_snapshot([_post('a'), _post('b')]));
      final afterInstall = provider.feedGeneration;

      provider.addPost(_post('mine', author: 'me'));

      expect(provider.feedGeneration, afterInstall,
          reason: 'a local edit must not restart the list');
      expect(provider.posts.first.id, 'mine');
    });

    test('a splice updates the ranking of record, not just the working list',
        () {
      // THE BUG, IN ONE ASSERTION. `_posts` and `_installed.posts` used to
      // diverge the moment anything was inserted locally, and every comparison
      // downstream then reasoned about a feed that was not on screen.
      provider.debugInstall(_snapshot([_post('a'), _post('b')]));
      provider.addPost(_post('mine', author: 'me'));

      expect(
        provider.debugInstalled!.orderedPostIds,
        provider.posts.map((p) => p.id).toList(),
      );
      expect(provider.debugInstalled!.orderedPostIds.first, 'mine');
    });

    test('a splice preserves what the snapshot IS', () {
      // Source, identity and placeholder-ness all have to survive an edit, or a
      // spliced cache page would silently become evidence that the marketplace
      // is empty.
      final cached = _snapshot([_post('a')], fromCache: true);
      provider.debugInstall(cached);
      provider.addPost(_post('mine', author: 'me'));

      expect(provider.debugInstalled!.fromCache, isTrue);
      expect(provider.debugInstalled!.identity.queryKey, cached.identity.queryKey);
    });
  });

  group('your own post is never announced back to you', () {
    late AppProvider provider;

    setUp(() {
      provider = AppProvider();
      provider.debugSetViewerId('me');
    });
    tearDown(() => provider.dispose());

    test('a rebuild whose only new listing is mine offers nothing', () {
      provider.debugInstall(_snapshot([_post('a'), _post('b')]));
      // What the server returns after the author publishes: their listing, plus
      // the posts that were already there.
      final rebuilt = _snapshot([
        _post('a'),
        _post('mine', author: 'me'),
        _post('b'),
      ]);

      expect(provider.debugWorthOffering(rebuilt), isFalse);
    });

    test('...and the count excludes it even when something else is new', () {
      provider.debugInstall(_snapshot([_post('a')]));
      final rebuilt = _snapshot([
        _post('fresh'),
        _post('mine', author: 'me'),
        _post('a'),
      ]);
      provider.debugArrive(rebuilt, FeedInvalidation.authored);

      expect(provider.hasPendingFeed, isTrue);
      expect(provider.pendingFeedNewPostCount, 1,
          reason: 'one genuinely new listing, not two');
    });

    test('a third-party post while scrolling IS offered', () {
      provider.debugInstall(_snapshot([_post('a')]));
      provider.setDiscoverVisible(true);
      provider.setFeedEngaged(true);

      provider.debugArrive(
        _snapshot([_post('fresh'), _post('a')]),
        FeedInvalidation.expired,
      );

      expect(provider.hasPendingFeed, isTrue);
    });

    test('a pure re-ranking with nothing new is silent', () {
      // The order changed; the corpus did not. A prompt here reorders familiar
      // cards for no reason, which is what teaches people to ignore prompts.
      provider.debugInstall(_snapshot([_post('a'), _post('b')]));
      provider.setDiscoverVisible(true);
      provider.setFeedEngaged(true);

      provider.debugArrive(
        _snapshot([_post('b'), _post('a')]),
        FeedInvalidation.expired,
      );

      expect(provider.hasPendingFeed, isFalse);
    });

    test('a ranking that overran the splash is OFFERED, never applied', () {
      // THE LAUNCH BLINK, END TO END.
      //
      // The feed request outran the deadline, so the splash handed over on the
      // chronological stand-in — which is exactly what a stand-in is for. The
      // ranked page then arrives while the reader is looking at the result. It
      // must not land: a generation bump re-keys Discover's list and crossfades
      // the whole feed, which is the blink itself.
      provider.debugInstall(_snapshot(
        [_post('a'), _post('b'), _post('c')],
        source: FeedSource.fallback,
        fromCache: true,
      ));
      final generationAtHandover = provider.feedGeneration;

      provider.debugArrive(
        _snapshot([_post('c'), _post('a'), _post('b')]),
        FeedInvalidation.expired,
      );

      expect(provider.feedGeneration, generationAtHandover,
          reason: 'nothing may re-key the list after the handover');
      expect(provider.hasPendingFeed, isTrue,
          reason: 'the better page is offered, not discarded');
      expect(provider.posts.map((p) => p.id), ['a', 'b', 'c'],
          reason: 'the cards the reader is looking at have not moved');
    });

    test('...and lands the moment the reader asks for it', () {
      provider.debugInstall(_snapshot(
        [_post('a'), _post('b')],
        source: FeedSource.fallback,
        fromCache: true,
      ));
      provider.debugArrive(
        _snapshot([_post('b'), _post('a')]),
        FeedInvalidation.expired,
      );
      final held = provider.feedGeneration;

      provider.applyPendingFeed();

      expect(provider.feedGeneration, held + 1);
      expect(provider.posts.map((p) => p.id), ['b', 'a']);
      expect(provider.hasPendingFeed, isFalse);
    });

    test('a reconnect rebuilds quietly instead of replacing the feed', () {
      // A connection coming back is the app noticing, not the user asking. It
      // used to be reported as `explicit` because the handler calls refreshAll,
      // so connectivity flapping during a launch could replace the feed twice.
      provider.debugInstall(_snapshot([_post('a'), _post('b')]));
      final before = provider.feedGeneration;

      provider.debugArrive(
        _snapshot([_post('fresh'), _post('a'), _post('b')]),
        FeedInvalidation.reconnected,
      );

      expect(provider.feedGeneration, before);
      expect(provider.hasPendingFeed, isTrue);
    });

    test('a ranking that overran the splash still replaces the stand-in', () {
      // The cold-ranker launch: the deadline handed over on the chronological
      // page, and the ranked one lands afterwards holding the SAME listings in
      // a better order. Nothing is "new", so the ordinary rule would discard it
      // silently and strand the reader on a page that was never ranked.
      final placeholder = _snapshot(
        [_post('a'), _post('b')],
        source: FeedSource.fallback,
        fromCache: true,
      );
      provider.debugInstall(placeholder);

      expect(
        provider.debugWorthOffering(_snapshot([_post('b'), _post('a')])),
        isTrue,
      );
    });

    test('...but not when the only arrival is still my own post', () {
      // The placeholder rule must never become a way for the author's own
      // listing to produce a banner.
      final placeholder = _snapshot(
        [_post('a')],
        source: FeedSource.fallback,
        fromCache: true,
      );
      provider.debugInstall(placeholder);

      expect(
        provider.debugWorthOffering(
          _snapshot([_post('mine', author: 'me'), _post('a')]),
        ),
        isFalse,
      );
    });

    test('the chronological fallback never claims to have recommendations', () {
      // Help24 recommends rather than enumerates, so only the engine may offer
      // recommendations. During a ranking outage the feed simply stays calm.
      provider.debugInstall(_snapshot([_post('a')]));
      final fallback = _snapshot([_post('fresh'), _post('a')],
          source: FeedSource.fallback);

      expect(provider.debugWorthOffering(fallback), isFalse);
    });

    test('an anonymous browser has no own posts to suppress', () {
      // The suppression keys off an exact author-id match. With no viewer there
      // is nobody to match, so it must switch itself off entirely rather than
      // silently swallow everything written by the empty string.
      final anon = AppProvider();
      addTearDown(anon.dispose);
      anon.debugInstall(_snapshot([_post('a')]));

      expect(
        anon.debugWorthOffering(_snapshot([_post('fresh'), _post('a')])),
        isTrue,
      );
    });
  });

  group('newPostCountSince counts what the reader would call new', () {
    final current = _snapshot([_post('a'), _post('b')]);

    test('ignores posts already on screen', () {
      expect(current.newPostCountSince(current), 0);
    });

    test('counts arrivals', () {
      final next = _snapshot([_post('c'), _post('a'), _post('b')]);
      expect(next.newPostCountSince(current), 1);
    });

    test('excludes the author when asked', () {
      final next = _snapshot([
        _post('mine', author: 'me'),
        _post('c'),
        _post('a'),
        _post('b'),
      ]);
      expect(next.newPostCountSince(current), 2);
      expect(next.newPostCountSince(current, excludingAuthor: 'me'), 1);
    });

    test('an empty author id excludes nothing', () {
      // Most posts parse with `authorUserId == ''` when the server omits it.
      // Treating the empty string as an identity would suppress every one of
      // them, which is a silent, total failure of the prompt.
      final next = _snapshot([_post('c', author: ''), _post('a'), _post('b')]);
      expect(next.newPostCountSince(current, excludingAuthor: ''), 1);
    });
  });
}
