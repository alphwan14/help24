import 'package:flutter/foundation.dart';
import '../config/app_firebase.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/location_provider.dart';
import '../utils/feed_scope.dart';
import 'auth_service.dart';
import 'feed_service.dart';
import 'post_service.dart';

/// Splash-time data prefetch.
///
/// main() calls [begin] right after Supabase.initialize — while the native
/// splash is still on screen — so the first-screen network requests are
/// already in flight before the widget tree even builds. AppProvider's initial
/// loads then CONSUME these futures (take-once) instead of issuing new
/// requests: if the response arrived during the splash the feed is populated
/// on the very first frame; if not, the existing skeleton loaders show for the
/// remaining wait, exactly as before.
///
/// Failure-safe by design: every future resolves to null on ANY error (it
/// never throws), and a null result makes AppProvider fall through to its
/// unchanged normal path — connectivity check, offline cache, retry states.
/// With no internet the app therefore behaves byte-for-byte like today.
///
/// WHAT CHANGED, AND WHY IT MATTERS
/// --------------------------------
/// This used to prefetch a CHRONOLOGICAL page and nothing else, which meant the
/// only thing ready at launch was a page the app had already decided not to
/// show. The real ranking could not even be REQUESTED until the widget tree
/// built, auth restored, HomeScreen's post-frame callback ran and the location
/// provider had read its prefs — a second or more after Discover appeared. So
/// the ranking landed on a user who was already reading, and rearranged the
/// feed under their thumb.
///
/// [feed] closes that gap: the restored uid and the stored coordinates are both
/// readable without a widget tree, so the RANKED request goes out during the
/// splash, computed for the right person from the right place. AppProvider
/// adopts the identity it was computed under, which is what makes the later
/// `setViewer` from HomeScreen a no-op instead of a second full reload.
class StartupPrefetch {
  StartupPrefetch._();

  /// How long the launch ranking waits for Firebase to say who is signed in.
  ///
  /// `currentUser` is null for a short window after `initializeApp` while
  /// persistence is read, so asking it directly would rank a signed-in user
  /// anonymously — and then re-rank a second later, which is the cold-start
  /// reshuffle. `authStateChanges` emits once persistence has settled; this is
  /// the bound on how long that is worth waiting for.
  static const Duration _viewerWait = Duration(milliseconds: 1500);

  static Future<List<PostModel>?>? _posts;
  static Future<List<JobModel>?>? _jobs;
  static Future<List<PostModel>?>? _urgent;
  static Future<StartupFeed?>? _feed;

  /// The identity the launch ranking was computed under, once known.
  ///
  /// Read SYNCHRONOUSLY by AppProvider so that a `setViewer` arriving while the
  /// request is still in flight can recognise that the answer already on its way
  /// is the answer it would have asked for, and issue nothing.
  static StartupViewer? _viewer;
  static StartupViewer? get viewer => _viewer;

  /// Start the first-screen fetches (fire-and-forget). Mirrors the exact
  /// queries AppProvider issues at startup with default filter state.
  static void begin() {
    // Scoped exactly as AppProvider's fallback scopes them. An unscoped prefetch
    // would hand the feed job posts and non-open listings that the very next
    // load removes — the splash would paint one Discover and the first refresh
    // would paint a different one.
    _posts = _guard(
        'posts',
        () => PostService.fetchPosts(
            filters: const PostFilters().forScope(FeedScope.all)));
    _jobs = _guard(
        'jobs',
        () => PostService.fetchJobs(
            filters: const PostFilters().forScope(FeedScope.jobs)));
    // Same page size AppProvider uses, so consuming the prefetch cannot produce
    // a shorter urgent list — and therefore a different badge count — than a
    // live load of the same data.
    _urgent = _guard('urgent',
        () => PostService.fetchUrgentPosts(limit: AppProvider.urgentPageSize));
    // The launch ranking. Deliberately started AFTER the three reads above so it
    // never queues behind its own fallback, and deliberately handed `_posts` as
    // that fallback so a backend too cold to rank still costs one round trip.
    _feed = _guard('feed', _rankForLaunch);
  }

  /// Rank Discover's default page for whoever this device is signed in as.
  static Future<StartupFeed> _rankForLaunch() async {
    final viewer = await _restoreViewer();
    _viewer = viewer;
    final result = await FeedService.fetchFeed(
      userId: viewer.userId,
      latitude: viewer.latitude,
      longitude: viewer.longitude,
      scope: FeedScope.all,
      filters: const PostFilters(),
      // Deliberately NOT `takePosts()`: the same chronological read is also what
      // Discover paints if ranking turns out to be slow (see
      // AppProvider._paintEarlyPageIfRankingIsSlow), and consuming the slot here
      // would take that page away from the screen that may need it.
      warmFallback: _posts,
    );
    debugPrint('[STARTUP_PREFETCH] launch ranking: ${result.items.length} posts '
        '(${result.source.name}, viewer=${viewer.userId ?? 'anonymous'})');
    return StartupFeed(result: result, viewer: viewer);
  }

  /// Who is looking, and from where — without a BuildContext.
  static Future<StartupViewer> _restoreViewer() async {
    String? uid;
    try {
      await AppFirebase.initialize();
      uid = AuthService.currentFirebaseUser?.uid ??
          (await AuthService.authStateChanges.first.timeout(_viewerWait))?.uid;
    } catch (e) {
      // A timeout here means "we could not find out in time", which is the
      // anonymous case: rank without a viewer rather than delay the feed.
      debugPrint('[STARTUP_PREFETCH] viewer unresolved at launch ($e)');
      uid = AuthService.currentFirebaseUser?.uid;
    }
    if (uid == null || uid.isEmpty) return const StartupViewer();
    final at = await LocationProvider.lastKnownCoordinates(uid);
    return StartupViewer(
      userId: uid,
      latitude: at.latitude,
      longitude: at.longitude,
    );
  }

  /// The chronological splash read, WITHOUT consuming it.
  ///
  /// One page, two possible jobs: the ranked request's degradation source, and —
  /// when the ranking backend is cold enough that waiting for it would mean
  /// seconds of shimmer over a page we are already holding — something real to
  /// put on screen in the meantime. It is only ever painted as a placeholder,
  /// so the ranked page still replaces it outright when it arrives.
  static Future<List<PostModel>?>? get earlyPosts => _posts;

  /// Take-once accessors: return the in-flight future and clear the slot so a
  /// pull-to-refresh or filter change can never be served stale prefetch data.
  static Future<List<PostModel>?>? takePosts() {
    final f = _posts;
    _posts = null;
    return f;
  }

  static Future<List<JobModel>?>? takeJobs() {
    final f = _jobs;
    _jobs = null;
    return f;
  }

  static Future<List<PostModel>?>? takeUrgentPosts() {
    final f = _urgent;
    _urgent = null;
    return f;
  }

  /// The launch ranking, take-once. Null once consumed (or if [begin] never ran,
  /// which is every widget test).
  static Future<StartupFeed?>? takeFeed() {
    final f = _feed;
    _feed = null;
    return f;
  }

  /// Whether the launch ranking is still the newest answer for [userId] at
  /// [latitude]/[longitude] — i.e. whether re-requesting it would return what is
  /// already on its way.
  static bool answers({String? userId, double? latitude, double? longitude}) {
    final v = _viewer;
    if (v == null) return false;
    return v.userId == userId &&
        v.latitude == latitude &&
        v.longitude == longitude;
  }

  /// Test seam: forget every slot so an isolated test starts from a cold app.
  @visibleForTesting
  static void resetForTest() {
    _posts = null;
    _jobs = null;
    _urgent = null;
    _feed = null;
    _viewer = null;
  }

  static Future<T?> _guard<T>(String label, Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      debugPrint('[STARTUP_PREFETCH] $label prefetch unavailable ($e) — normal load path takes over');
      return null;
    }
  }
}

/// The identity the launch ranking was computed under.
@immutable
class StartupViewer {
  final String? userId;
  final double? latitude;
  final double? longitude;

  const StartupViewer({this.userId, this.latitude, this.longitude});
}

/// A ranked Discover page computed before the first frame, with the identity it
/// was computed under attached — so the provider can adopt both together.
@immutable
class StartupFeed {
  final FeedResult<PostModel> result;
  final StartupViewer viewer;

  const StartupFeed({required this.result, required this.viewer});
}
