import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/post_model.dart';
import '../models/theme_preference.dart';
import '../services/post_service.dart';
import '../services/chat_service_supabase.dart';
import '../services/application_service.dart';
import '../services/auth_service.dart';
import '../services/cache_service.dart';
import '../services/feed_service.dart';
import '../services/feed_snapshot.dart';
import '../services/interaction_tracker.dart';
import '../services/jobs_service.dart';
import '../services/session_scope.dart';
import '../services/startup_prefetch.dart';
import '../utils/error_mapper.dart';
import '../utils/feature_errors.dart';
import '../utils/feed_scope.dart';
import '../utils/proximity.dart';

class AppProvider extends ChangeNotifier implements SessionScoped {
  ThemePreference _themePreference = ThemePreference.system;
  List<PostModel> _posts = [];
  List<PostModel> _urgentPosts = [];
  List<JobModel> _jobs = [];
  List<Conversation> _conversations = [];
  StreamSubscription<List<Conversation>>? _conversationStreamSubscription;
  
  // Loading states
  bool _isLoadingPosts = false;
  bool _isLoadingJobs = false;
  bool _isLoadingUrgentPosts = false;
  bool _isLoadingConversations = false;
  bool _isPosting = false;

  /// One error slot per feature — see utils/feature_errors.dart.
  ///
  /// This replaces a single shared `String? _error` that five features wrote and
  /// four read, which both leaked one feature's failure into another's UI and
  /// erased failures before they could be shown (loadPosts and loadJobs run
  /// concurrently and each cleared the slot on entry).
  final FeatureErrors _errors = FeatureErrors();
  
  // Filter state
  String _searchQuery = '';
  String _selectedFilter = 'All';
  Set<String> _selectedCategories = {};
  String _selectedCity = '';
  String _selectedArea = '';
  RangeValues _priceRange = const RangeValues(0, 100000);
  Difficulty? _selectedDifficulty;
  Urgency? _selectedUrgency;

  // ── Viewer context (drives the recommendation engine) ────────────────────
  //
  // Replaces `_priorityLocationCity`, which was set on every sign-in and read
  // by nothing: no sort, no filter, no query parameter. Proximity is now real
  // coordinates travelling to the ranking engine, never a city substring —
  // see _docs/RECOMMENDATION_ENGINE_AUDIT.md §3.2.
  String? _viewerUserId;
  double? _viewerLatitude;
  double? _viewerLongitude;

  /// Bumped whenever the signed-in user's profile or profession changes, so a
  /// ranking computed under the old profile can be recognised as stale without
  /// this provider having to know what a profession is.
  int _profileRevision = 0;

  // ── Feed stability ────────────────────────────────────────────────────────
  //
  // Discover renders a FROZEN ranking. See services/feed_snapshot.dart for the
  // full argument; the short version is that ranking used to be something the
  // feed did while you were reading it, and four independent callers were each
  // allowed to re-sort the cards under the reader's thumb.
  //
  // `_installed` is the ranking on screen. `_pending` is a newer one that has
  // been computed but NOT shown, because showing it would move things the user
  // is looking at. `_posts` stays the mutable working list so that local
  // splices (an optimistic insert, an archive) keep working — they change the
  // contents, never the order.

  /// The ranking currently on screen. Null until the first one lands.
  FeedSnapshot? _installed;

  /// A newer ranking, computed and waiting for permission to land.
  FeedSnapshot? _pending;

  /// Bumped every time a snapshot is installed. Discover keys its list on this
  /// so a REPLACEMENT crossfades, while an in-place edit of the same ranking (an
  /// optimistic insert, an archive, an "Applied" badge flipping) rebuilds the
  /// existing list and keeps its scroll position.
  int _feedGeneration = 0;

  /// Whether the Jobs tab has ever completed a load. Same distinction Discover
  /// draws with [FeedPresentation]: until a request has actually answered, an
  /// empty list means "not yet", not "there are no jobs".
  bool _jobsResolved = false;

  /// Whether Discover is the visible tab. A rebuild that arrives while the user
  /// is somewhere else can simply be installed — there is nothing on screen to
  /// disturb, which is the quietest possible way to refresh.
  bool _discoverVisible = true;

  /// Whether the identity the feed is ranked for is KNOWN.
  ///
  /// The first ranking waits for it. Without this the cold start ranks
  /// anonymously, paints, and then re-ranks the instant the restored session
  /// resolves — a full reorder about a second after Discover appears, every
  /// single launch.
  ///
  /// Normally set by the launch ranking (StartupPrefetch resolves the restored
  /// uid before the first frame); [setViewer] and [_viewerGrace] are the two
  /// fallbacks for when that could not run.
  bool _viewerResolved = false;
  Timer? _viewerGraceTimer;

  /// How long the first ranking waits for an identity before going ahead
  /// without one. Long enough for a restored Firebase session to resolve, short
  /// enough that a signed-out browser is not kept waiting.
  ///
  /// A BACKSTOP now rather than the normal path: the launch ranking already
  /// waited for Firebase off-screen, so this only fires when the prefetch never
  /// ran (widget tests) or died.
  static const Duration _viewerGrace = Duration(milliseconds: 900);

  /// Whether the reader is somewhere other than the top of the feed.
  ///
  /// Scrolling is the clearest statement of "I am reading this" the app ever
  /// receives, and the two remaining paths that may replace a visible feed
  /// without being asked — swapping out the on-disk placeholder, and gaining
  /// coordinates for the first time — are exactly the ones that land a second or
  /// two into a launch, which is precisely when someone has started to scroll.
  /// While this is true they are offered instead. See [_shouldInstall].
  bool _readerEngaged = false;

  /// Rankings for questions the user has recently asked, keyed by
  /// [FeedIdentity.queryKey] — All, Requests, Offers, and whatever filtered
  /// pages they passed through.
  ///
  /// Switching tabs used to mean skeletons: the installed page answered another
  /// question, so Discover had nothing to render until a scoped fetch came back.
  /// The ranking for that tab was usually a few seconds old and perfectly good —
  /// it had simply been thrown away. Keeping it makes a tab switch instant, and
  /// [_warmOtherScopes] makes the FIRST switch instant too by computing the
  /// other two tabs at launch, while nobody is looking at them.
  final Map<String, FeedSnapshot> _snapshotsByQuery = {};

  /// Enough for the three tabs plus a couple of filtered pages. Bounded because
  /// this is a convenience cache, not a store of record.
  static const int _rememberedQueries = 6;

  /// Identity of the last jobs query, so the Jobs tab stops re-fetching (and
  /// re-ordering) for changes that cannot affect its ranking.
  FeedIdentity? _jobsIdentity;

  /// Monotonic request ids. Typing "electrician" used to fire eleven full feed
  /// queries with nothing sequencing them, so a slow early response could land
  /// after a fast later one and overwrite it (audit §3.7).
  int _postsRequestSeq = 0;
  int _jobsRequestSeq = 0;
  Timer? _searchDebounce;

  /// Long enough to swallow a burst of typing, short enough that the feed
  /// still feels like it is responding to the keyboard.
  static const Duration _searchDebounceDelay = Duration(milliseconds: 350);

  /// Post ids the current user has applied to / sent an offer on. Server-derived
  /// (from the applications table) so the "Applied / Offer sent" state is TRUE
  /// across refreshes, tab switches and app restarts — not a per-session flag
  /// that reverts on the next feed load and re-invites a duplicate.
  Set<String> _appliedPostIds = {};

  // Getters
  /// The user's theme choice (Device Default / Light / Dark).
  ThemePreference get themePreference => _themePreference;

  /// Fed straight to `MaterialApp.themeMode`.
  ThemeMode get themeMode => _themePreference.themeMode;
  /// Whether the current user has already applied / sent an offer on [postId].
  bool hasAppliedTo(String postId) => _appliedPostIds.contains(postId);
  List<PostModel> get posts => _posts;
  List<JobModel> get jobs => _jobs;
  List<PostModel> get urgentPosts => _urgentPosts;
  List<Conversation> get conversations => _conversations;
  bool get isLoadingPosts => _isLoadingPosts;
  bool get isLoadingJobs => _isLoadingJobs;
  bool get isLoadingUrgentPosts => _isLoadingUrgentPosts;
  bool get isLoadingConversations => _isLoadingConversations;
  bool get isPosting => _isPosting;
  /// Why the Discover feed failed to load, or null. Read ONLY by Discover.
  ///
  /// The generic `error` getter this replaces was read by Discover, Jobs and
  /// the posting screen alike, so each of them could render another's failure.
  String? get discoverError => _errors[AppFeature.discover];

  /// Why the Jobs tab failed to load, or null.
  String? get jobsError => _errors[AppFeature.jobs];

  /// Why the last create/archive failed, or null.
  String? get postingError => _errors[AppFeature.posting];

  /// Why urgent requests failed to load, or null.
  String? get urgentError => _errors[AppFeature.urgent];

  /// Why the conversation list failed to load, or null.
  String? get messagesError => _errors[AppFeature.messages];

  String get searchQuery => _searchQuery;
  String get selectedFilter => _selectedFilter;
  Set<String> get selectedCategories => _selectedCategories;
  String get selectedCity => _selectedCity;
  String get selectedArea => _selectedArea;
  RangeValues get priceRange => _priceRange;
  Difficulty? get selectedDifficulty => _selectedDifficulty;
  Urgency? get selectedUrgency => _selectedUrgency;

  /// Identity of the installed snapshot, bumped on every replacement. Discover
  /// keys its list on this to crossfade one ranking into the next.
  int get feedGeneration => _feedGeneration;

  /// What Discover is entitled to render right now — see [FeedPresentation].
  ///
  /// The screen used to derive this from `isLoadingPosts` and `posts.isEmpty`,
  /// which cannot distinguish "no request has run yet" from "the request ran and
  /// found nothing". At cold start the first ranking waits for the viewer
  /// identity ([_viewerGrace]), so for that window nothing was loading and the
  /// list was empty — and Discover announced an empty marketplace to every user
  /// opening the app, before the skeletons it should have shown instead.
  ///
  /// Absence of an answer resolves to [FeedPresentation.loading], the default.
  /// [FeedPresentation.empty] requires evidence and is terminal.
  FeedPresentation get feedPresentation => FeedPresentation.resolve(
        hasVisiblePosts: filteredPosts.isNotEmpty,
        hasAnswerForCurrentQuery: _hasAnswerForCurrentQuery,
        isLoading: _isLoadingPosts,
        hasError: _errors[AppFeature.discover] != null,
      );

  /// Whether a COMPLETED load stands behind what is (or is not) on screen for
  /// the question being asked right now.
  ///
  /// Excludes the on-disk placeholder deliberately: it is old by definition, so
  /// it may keep the screen alive but may never be the evidence behind "no posts
  /// found". Excludes a snapshot built for another tab or another filter set for
  /// the obvious reason — the Offers page says nothing about Requests.
  ///
  /// And excludes EVERYTHING until the viewer is resolved. A page fetched before
  /// the app knows who is signed in was computed for a viewer that is about to
  /// stop existing; treating it as an answer is what let a pre-identity result
  /// put "No posts found" on screen and then send Discover back to skeletons the
  /// moment the real identity landed — the empty→shimmer→feed sequence, which
  /// the presentation rule alone could not prevent because the pre-identity page
  /// looked like a perfectly good answer to a question nobody had asked yet.
  bool get _hasAnswerForCurrentQuery {
    if (!_viewerResolved) return false;
    final installed = _installed;
    if (installed == null || installed.fromCache) return false;
    return installed.identity
        .answersSameQuestionAs(_identityFor(_scopeForFilter, _currentFilters));
  }

  /// Whether the Jobs tab's empty list is an answer or an absence of one.
  bool get hasResolvedJobs => _jobsResolved;

  /// True when the ranking on screen came from the recommendation engine rather
  /// than the chronological fallback.
  bool get isFeedRanked => _installed?.isRanked ?? false;

  /// True when the server had enough about this viewer to personalise.
  bool get isFeedPersonalised => _installed?.personalised ?? false;

  /// Final recommendation score for [postId], when the page was ranked.
  double? feedScoreFor(String postId) => _installed?.scores[postId];

  /// Per-signal breakdown for [postId] — "Distance +28.4, Profession +25.0".
  /// Explainability surface for debugging and weight tuning.
  List<FeedSignalBreakdown> feedSignalsFor(String postId) =>
      _installed?.signals[postId] ?? const [];

  /// True when a newer ranking has been computed and is waiting to be shown.
  ///
  /// Discover renders this as "New recommendations available". It is never
  /// applied on its own: a feed that reorganises itself while someone reads it
  /// is the behaviour this whole mechanism exists to prevent.
  bool get hasPendingFeed => _pending != null;

  /// How many posts in the waiting ranking are ones the reader has not seen, so
  /// the prompt can say something true rather than something generic.
  int get pendingFeedNewPostCount {
    final next = _pending;
    final current = _installed;
    if (next == null) return 0;
    if (current == null) return next.posts.length;
    return next.newPostCountSince(current);
  }

  /// Show the waiting ranking. Called by the prompt and by pull-to-refresh —
  /// i.e. only ever as a direct result of the user asking.
  void applyPendingFeed() {
    final next = _pending;
    if (next == null) return;
    _pending = null;
    _install(next);
    notifyListeners();
  }

  /// Discard the waiting ranking without showing it. Used when a newer, more
  /// authoritative load supersedes it.
  void _dropPendingFeed() => _pending = null;

  /// Tell the provider whether Discover is the tab in front of the user.
  ///
  /// A ranking that lands while they are reading Messages can just be installed:
  /// nothing is on screen to disturb, so the refresh is free and invisible.
  /// This is most of what "the user should hardly see the rebuild" means in
  /// practice.
  void setDiscoverVisible(bool visible) {
    if (_discoverVisible == visible) return;
    _discoverVisible = visible;
    // Leaving Discover is the ideal moment to cash in anything that was waiting.
    if (!visible && _pending != null) {
      // Nobody is reading it any more, so nothing can be disturbed by the swap.
      _readerEngaged = false;
      applyPendingFeed();
    }
  }

  /// Record that the signed-in user's profile or profession changed, which is
  /// one of the things that legitimately changes what should be recommended.
  ///
  /// Rebuilds quietly and OFFERS the result — a profile edit is not a request
  /// to have the feed reorganised underneath the screen you are on.
  void markProfileChanged() {
    _profileRevision++;
    unawaited(maybeRefreshFeed());
  }

  AppProvider({ThemePreference initialTheme = ThemePreference.system})
      : _themePreference = initialTheme {
    SessionScope.instance.register(this);
    _loadInitialData();
  }

  /// Destroy everything derived from the signed-in user.
  ///
  /// Synchronous by contract: it runs before the identity provider signs out,
  /// so no frame can paint the previous account's data during the transition.
  /// Posts, jobs and urgent posts are public marketplace data and deliberately
  /// survive — clearing them would blank the feed on every sign-out for no
  /// privacy gain.
  @override
  void resetForSignOut() {
    _conversationStreamSubscription?.cancel();
    _conversationStreamSubscription = null;
    _conversationsUserId = '';
    _conversationsSubscribedUserId = '';
    _errors.clear(AppFeature.messages);
    _conversations = [];
    _pagedConversationIds.clear();
    _hasMoreConversations = true;
    _isLoadingConversations = false;
    _loadingMoreConversations = false;
    _appliedPostIds = {};
    _activeChatId = null;
    _warmedAvatarUrls.clear();
    _errors.clearAll();
    // Personalisation is per-account: the outgoing user's profession, affinity
    // and queued behavioural events must not follow them out. Posts stay (they
    // are public marketplace data) but the ranking that shaped them does not.
    _viewerUserId = null;
    _viewerLatitude = null;
    _viewerLongitude = null;
    _profileRevision = 0;
    // The ranking itself is dropped, not just its metadata: it was computed for
    // an account that is no longer signed in. `_posts` deliberately survives —
    // the posts are public marketplace data and blanking Discover on sign-out
    // buys no privacy — but they are now an unranked list, which is what having
    // no installed snapshot means.
    _installed = null;
    _pending = null;
    _snapshotsByQuery.clear();
    _readerEngaged = false;
    _jobsIdentity = null;
    InteractionTracker.instance.setUser(null);
    notifyListeners();
  }

  /// Load initial data from Supabase (conversations loaded when Messages screen opens with user id)
  ///
  /// Discover is deliberately NOT loaded here. Its first ranking waits for
  /// [setViewer] so it can be computed for the right person, from the right
  /// place, ONCE — see [_viewerGrace]. Loading it now would rank anonymously,
  /// paint, and then re-rank a second later when the restored session resolves,
  /// which is the cold-start reshuffle users were reporting.
  Future<void> _loadInitialData() async {
    // Disk first, and NOT awaited by anything else: the last feed we had is on
    // screen within a frame or two of the widget tree building, long before the
    // viewer identity resolves and the first ranking is even requested. A warm
    // launch therefore shows posts, not skeletons.
    unawaited(_hydrateFromCache());
    unawaited(_openWithLaunchRanking());
    // Keeps the Discover header's Urgent count live across refresh/reconnect.
    await loadUrgentPosts();
  }

  /// Open on the ranking that was computed while the splash was still up.
  ///
  /// THE SEQUENCING THIS FIXES
  /// -------------------------
  /// The first ranking used to be requested from HomeScreen's post-frame
  /// callback, after auth restored and the location provider had read its prefs
  /// — a second or more after Discover was already on screen. Whatever it
  /// returned therefore arrived on a reader, and because a viewer change
  /// replaces the visible feed, it rearranged the cards under their thumb. The
  /// 900 ms grace timer made it worse on slow starts: it gave up waiting and
  /// ranked ANONYMOUSLY, so the sequence was a pre-identity page, then the real
  /// one, then a scroll position nobody chose.
  ///
  /// StartupPrefetch resolves the restored uid and the stored coordinates
  /// without a widget tree, so the ranked request goes out during the splash.
  /// This adopts BOTH the page and the identity it was computed under, which is
  /// what makes HomeScreen's later `setViewer` recognise it has nothing to do.
  ///
  /// Falls back to the old path on every failure: no prefetch (widget tests), a
  /// dead network, or a viewer that resolved elsewhere first.
  Future<void> _openWithLaunchRanking() async {
    final pending = StartupPrefetch.takeFeed();
    if (pending == null) {
      _armViewerGrace();
      return;
    }
    unawaited(_paintEarlyPageIfRankingIsSlow(pending));
    StartupFeed? startup;
    try {
      startup = await pending;
    } catch (e) {
      debugPrint('[AppProvider] launch ranking unavailable: $e');
    }

    // A live load already owns the feed — a tab, a filter, an explicit refresh.
    // Whatever the splash computed answers a question nobody is asking now.
    if (_postsRequestSeq > 0) return;
    // The viewer resolved to someone other than the person this was ranked for
    // (a sign-in during startup). Their feed is not this one.
    if (_viewerResolved &&
        !StartupPrefetch.answers(
          userId: _viewerUserId,
          latitude: _viewerLatitude,
          longitude: _viewerLongitude,
        )) {
      return;
    }

    if (startup == null || startup.result.items.isEmpty) {
      // Nothing usable. If setViewer already deferred to this request, the load
      // is now ours to issue; otherwise leave it to the identity path, which
      // still has a viewer to wait for.
      if (_viewerResolved) {
        unawaited(loadPosts(reason: FeedInvalidation.explicit));
        unawaited(loadJobs(force: true));
      } else {
        _armViewerGrace();
      }
      return;
    }

    final viewer = startup.viewer;
    _viewerUserId = viewer.userId;
    _viewerLatitude = viewer.latitude;
    _viewerLongitude = viewer.longitude;
    InteractionTracker.instance.setUser(viewer.userId);
    _viewerResolved = true;
    _viewerGraceTimer?.cancel();
    _viewerGraceTimer = null;

    final snapshot = FeedSnapshot.fromResult(
      startup.result,
      identity: _identityFor(FeedScope.all, const PostFilters()),
      generatedAt: DateTime.now(),
    );
    if (_isDefaultQuery) {
      _install(snapshot);
      _remember(snapshot);
      unawaited(CacheService.savePosts(snapshot.posts));
    } else {
      // The user changed the question before the splash answered. Keep the page
      // for when they come back to it; do not put it on screen.
      _remember(snapshot);
    }
    _warmAvatarUrls(snapshot.posts.map((p) => p.authorAvatar));
    notifyListeners();
    unawaited(loadJobs(force: true));
    unawaited(_warmOtherScopes());
  }

  /// How long Discover waits for a RANKED launch page before putting the
  /// chronological one on screen instead.
  ///
  /// The ranking backend sleeps when idle, and the client's own timeout is eight
  /// seconds — so the first launch of the day could mean eight seconds of
  /// shimmer over a page the app had already fetched and was holding in memory.
  /// Long enough that a healthy backend always wins the race (a warm ranked
  /// response lands in a few hundred milliseconds, and nothing is painted
  /// twice); short enough that a cold one costs a beat, not a wait.
  static const Duration _rankingPatience = Duration(milliseconds: 1200);

  /// Put the chronological splash page on screen if ranking is taking too long.
  ///
  /// Installed as a PLACEHOLDER, which is the whole reason this is safe: it can
  /// never be the evidence behind "No posts found", and the ranked page replaces
  /// it outright the moment it lands — unless the reader has started scrolling,
  /// in which case [FeedArrival] holds it back and offers it. Nothing is painted
  /// at all when the disk cache already filled the screen, when the user has
  /// changed the question, or when ranking simply arrives first.
  Future<void> _paintEarlyPageIfRankingIsSlow(Future<StartupFeed?> ranking) async {
    final early = StartupPrefetch.earlyPosts;
    if (early == null) return;
    var ranked = false;
    unawaited(ranking.then((_) => ranked = true, onError: (_) => ranked = true));

    List<PostModel>? posts;
    try {
      posts = await early;
    } catch (_) {
      return;
    }
    if (posts == null || posts.isEmpty) return;
    await Future<void>.delayed(_rankingPatience);
    if (ranked ||
        _installed != null ||
        _postsRequestSeq > 0 ||
        !_isDefaultQuery) {
      return;
    }
    debugPrint('[FEED] ranking still out at ${_rankingPatience.inMilliseconds}ms '
        '— showing the chronological page meanwhile');
    _install(FeedSnapshot(
      posts: posts,
      source: FeedSource.fallback,
      identity: _identityFor(FeedScope.all, const PostFilters()),
      // Born expired, like every other placeholder: it was never ranked for
      // this viewer, so anything that considers refreshing should rebuild.
      generatedAt: DateTime.now().subtract(FeedSnapshot.ttl),
      fromCache: true,
    ));
    _warmAvatarUrls(posts.map((p) => p.authorAvatar));
    notifyListeners();
  }

  /// Rank the tabs nobody is looking at yet.
  ///
  /// Requests and Offers are the same corpus the All page just ranked, but the
  /// server applies the scope as a hard constraint, so a scoped page is not
  /// something the client can derive — it can only approximate it by filtering
  /// (which is what [_seedFor] does when this has not landed yet).
  /// Computing them at launch, while Discover is showing All, is what makes the
  /// first tap on either tab instant instead of a shimmer.
  ///
  /// Silent and best-effort: two requests, no UI, no errors, nothing installed.
  Future<void> _warmOtherScopes() async {
    if (!_isDefaultQuery) return;
    for (final scope in const [FeedScope.requests, FeedScope.offers]) {
      final identity = _identityFor(scope, const PostFilters());
      if (_snapshotsByQuery.containsKey(identity.queryKey)) continue;
      try {
        final result = await FeedService.fetchFeed(
          userId: _viewerUserId,
          latitude: _viewerLatitude,
          longitude: _viewerLongitude,
          scope: scope,
          filters: const PostFilters(),
        );
        if (result.items.isEmpty) continue;
        // Re-checked across the await: the user may have signed in or filtered
        // while this ran, which would make the page answer nothing.
        if (!identity.answersSameQuestionAs(_identityFor(scope, const PostFilters()))) {
          continue;
        }
        _remember(FeedSnapshot.fromResult(
          result,
          identity: identity,
          generatedAt: DateTime.now(),
        ));
      } catch (e) {
        debugPrint('[FEED] warm ${scope.wire} skipped ($e)');
      }
    }
  }

  /// The backstop for a launch where the ranking prefetch never ran or failed.
  void _armViewerGrace() {
    if (_viewerResolved || _viewerGraceTimer != null) return;
    _viewerGraceTimer = Timer(_viewerGrace, () {
      if (_viewerResolved) return;
      _viewerResolved = true;
      unawaited(loadPosts(reason: FeedInvalidation.explicit));
      unawaited(loadJobs());
    });
  }

  /// The query every cold start begins on: All tab, no search, no filters.
  ///
  /// The disk cache holds exactly this page and nothing else (see [loadPosts]),
  /// so it is only ever written and read as an answer to this one question.
  /// Caching a filtered page would mean the next cold start opened on someone's
  /// leftover "plumbing in Kilimani" as though it were the marketplace.
  static final String _defaultQueryKey =
      FeedIdentity.describeQuery(FeedScope.all, const PostFilters());

  bool get _isDefaultQuery =>
      FeedIdentity.describeQuery(_scopeForFilter, _currentFilters) ==
          _defaultQueryKey;

  /// Search box empty and no explicit filters — the Jobs tab's equivalent of
  /// [_isDefaultQuery] (it has one scope, so the Discover tab selection is not
  /// part of its question).
  bool get _isUnfilteredQuery => _searchQuery.isEmpty && !hasActiveFilters;

  /// Persist the feed for the next cold start — but only when what is in memory
  /// IS what a cold start opens on.
  ///
  /// Every write goes through these two so the rule cannot be forgotten at one
  /// of the five call sites. Caching a filtered, searched or tab-scoped list
  /// would hydrate the next launch with an answer to a question nobody asked,
  /// and the user would open the app on a marketplace that looked like their
  /// last search.
  void _cachePostsIfDefault() {
    if (!_isDefaultQuery || _posts.isEmpty) return;
    unawaited(CacheService.savePosts(_posts));
  }

  void _cacheJobsIfDefault() {
    if (!_isUnfilteredQuery || _jobs.isEmpty) return;
    unawaited(CacheService.saveJobs(_jobs));
  }

  /// Put the last known feed on screen while the live one is computed.
  ///
  /// Installed as a PLACEHOLDER ([FeedSnapshot.fromCache]), which has two
  /// consequences that matter: it can never be mistaken for evidence that the
  /// marketplace is empty, and the first real snapshot replaces it outright
  /// instead of being held back behind a "New recommendations" prompt — nobody
  /// is attached to the order of a page we read off the disk.
  ///
  /// Silent on every failure. A cache miss simply leaves the screen in
  /// [FeedPresentation.loading], which is where a fresh install belongs.
  Future<void> _hydrateFromCache() async {
    if (_installed != null) return;
    final cached = await CacheService.loadPosts();
    // Re-checked across the await: a live load, a sign-in or a filter change may
    // have overtaken the disk read, and disk data must never win against any of
    // them.
    if (cached.isEmpty || _installed != null || !_isDefaultQuery) return;
    _install(FeedSnapshot(
      posts: cached,
      source: FeedSource.fallback,
      identity: _identityFor(FeedScope.all, const PostFilters()),
      // Born expired: these posts were never ranked for this viewer, so the very
      // next thing that considers refreshing should rebuild rather than wait out
      // a ten-minute TTL.
      generatedAt: DateTime.now().subtract(FeedSnapshot.ttl),
      fromCache: true,
    ));
    notifyListeners();

    // Same contract for Jobs — the tab opens on content instead of skeletons.
    // `_jobsResolved` stays false: this is a placeholder, so an empty Jobs list
    // still reads as "not yet", never as "no jobs exist".
    if (_jobs.isEmpty) {
      final cachedJobs = await CacheService.loadJobs();
      if (cachedJobs.isNotEmpty && _jobs.isEmpty) {
        _jobs = cachedJobs;
        notifyListeners();
      }
    }
  }

  /// Refresh all data
  Future<void> refreshAll() async {
    await Future.wait([
      loadPosts(reason: FeedInvalidation.explicit),
      loadJobs(force: true),
      loadUrgentPosts(),
    ]);
  }

  /// The conditions a feed request would be issued under right now.
  FeedIdentity _identityFor(FeedScope scope, PostFilters filters) => FeedIdentity.of(
        userId: _viewerUserId,
        latitude: _viewerLatitude,
        longitude: _viewerLongitude,
        profileRevision: _profileRevision,
        scope: scope,
        filters: filters,
      );

  /// The explicit filters currently in force. One definition, so the ranked
  /// request, the fallback query and the snapshot identity cannot disagree
  /// about what was asked for.
  PostFilters get _currentFilters => PostFilters(
        searchQuery: _searchQuery.isNotEmpty ? _searchQuery : null,
        categories:
            _selectedCategories.isNotEmpty ? _selectedCategories.toList() : null,
        city: _selectedCity.isNotEmpty ? _selectedCity : null,
        area: _selectedArea.isNotEmpty ? _selectedArea : null,
        urgency: _selectedUrgency?.name,
        minPrice: _priceRange.start > 0 ? _priceRange.start : null,
        maxPrice: _priceRange.end < 100000 ? _priceRange.end : null,
        difficulty: _selectedDifficulty?.name,
      );

  /// Rebuild the feed IF something that feeds the ranking actually changed.
  ///
  /// This is the automatic path — app resume, a location update, a profile
  /// edit, the snapshot ageing out. It never disturbs the screen: whatever it
  /// computes is offered through [hasPendingFeed], not installed.
  ///
  /// Cheap to call as often as you like: with nothing changed and a fresh
  /// snapshot it issues no request at all.
  Future<void> maybeRefreshFeed() async {
    final installed = _installed;
    if (installed == null) {
      // Nothing on screen yet — this is a first load, not a refresh.
      if (_viewerResolved) await loadPosts(reason: FeedInvalidation.explicit);
      return;
    }
    final next = _identityFor(_scopeForFilter, _currentFilters);
    var reason = installed.identity.invalidationFrom(next);
    if (reason.isNone && installed.isExpiredAt(DateTime.now())) {
      reason = FeedInvalidation.expired;
    }
    if (reason.isNone) return;
    await loadPosts(reason: reason);
  }

  // ==================== POSTS ====================

  /// Compute a Discover ranking and decide whether the user gets to see it.
  ///
  /// THE ONE RULE
  /// ------------
  /// Ranking happens off-screen and finishes before anything is presented.
  /// Whether the result reaches the screen depends entirely on [reason]:
  ///
  ///   * the user did something (refresh, filter, tab, sign-in) → install it,
  ///     because they are waiting for exactly this;
  ///   * the app noticed something (moved, profile edited, snapshot aged) →
  ///     compute it, hold it, and offer it as "New recommendations available".
  ///
  /// The second case is the whole point. A better feed is not a licence to
  /// reorganise a screen someone is reading.
  ///
  /// When offline: keeps the installed ranking, does not clear it or spin.
  Future<void> loadPosts({FeedInvalidation reason = FeedInvalidation.explicit}) async {
    final seq = ++_postsRequestSeq;
    final scope = _scopeForFilter;
    final filters = _currentFilters;
    final identity = _identityFor(scope, filters);

    // Only show a spinner when there is genuinely nothing to look at — not even
    // the on-disk placeholder. A background rebuild must be completely invisible
    // until it has something to offer.
    //
    // Note this is NOT what drives the skeletons any more: an empty Discover
    // with no request in flight already resolves to FeedPresentation.loading. It
    // survives as the "this load has nothing behind it" flag that decides
    // whether a failure is the user's problem.
    final firstPaint = _installed == null;
    if (firstPaint) {
      _isLoadingPosts = true;
      _errors.clear(AppFeature.discover);
      notifyListeners();
    }

    try {
      // The splash-time chronological read (take-once), used here as the ranked
      // request's fallback so a warm result still saves a round trip on the one
      // path that needs it: a backend too cold to rank. Painting it is the
      // launch path's decision, not this one's, and it is bounded — see
      // [_paintEarlyPageIfRankingIsSlow], which installs it as a placeholder
      // only when ranking has already kept the screen on shimmer too long.
      final prefetch = StartupPrefetch.takePosts();
      final usablePrefetch = prefetch != null &&
              !hasActiveFilters &&
              _searchQuery.isEmpty &&
              _selectedFilter == 'All'
          ? prefetch
          : null;

      final results = await Connectivity().checkConnectivity();
      final offline = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
      if (offline) {
        // Offline is not a reason to change what is on screen. Only hydrate
        // from disk when there is nothing there at all.
        if (firstPaint) {
          final cached = await CacheService.loadPosts();
          if (cached.isNotEmpty && seq == _postsRequestSeq) {
            _install(FeedSnapshot(
              posts: cached,
              source: FeedSource.fallback,
              identity: identity,
              // Born expired. These posts were never ranked for this viewer —
              // they are the last thing we happened to have on disk — so the
              // first thing that wakes the app after connectivity returns
              // should rebuild rather than wait out a ten-minute TTL.
              generatedAt: DateTime.now().subtract(FeedSnapshot.ttl),
              // Disk, therefore a placeholder — same as [_hydrateFromCache].
              // Without this the offline feed would count as an answer, so a
              // reconnect would offer its replacement behind a "New
              // recommendations" prompt instead of simply landing, and an old
              // cached page could stand behind "No posts found".
              fromCache: true,
            ));
          }
        }
        if (seq == _postsRequestSeq) {
          _isLoadingPosts = false;
          notifyListeners();
        }
        return;
      }

      // The ranked feed. On any failure — cold backend, timeout, 5xx — this
      // degrades inside FeedService to the exact `created_at DESC` Supabase
      // query the app used before the engine existed, so ranking can never be
      // the reason Discover is empty.
      var result = await FeedService.fetchFeed(
        userId: _viewerUserId,
        latitude: _viewerLatitude,
        longitude: _viewerLongitude,
        scope: scope,
        filters: filters,
        warmFallback: usablePrefetch,
      );

      // A newer load started while this one was in flight — drop it rather than
      // letting a stale page overwrite a fresh one.
      if (seq != _postsRequestSeq) return;

      // LOOK TWICE BEFORE SAYING THE MARKETPLACE IS EMPTY.
      //
      // Zero rows is the one result that changes what the app TELLS someone,
      // and it is reachable without anything being wrong: a warm fallback that
      // resolved to an empty list is indistinguishable, at this point, from a
      // query that genuinely matched nothing. FeedService already re-checks an
      // empty RANKED page against the database; this closes the same hole on
      // every other path, at the cost of one read on the only path where the
      // answer is "there is nothing here".
      if (result.items.isEmpty) {
        debugPrint('[FEED] empty page for "${identity.queryKey}" — confirming');
        final confirmation =
            await PostService.fetchPosts(filters: filters.forScope(scope));
        if (seq != _postsRequestSeq) return;
        if (confirmation.isNotEmpty) {
          result = FeedResult<PostModel>(
            items: confirmation,
            source: FeedSource.fallback,
          );
        }
      }

      final snapshot = FeedSnapshot.fromResult(
        result,
        identity: identity,
        generatedAt: DateTime.now(),
      );
      _remember(snapshot);

      // The request answered, so whatever failure was on screen is over.
      _errors.clear(AppFeature.discover);

      if (_shouldInstall(snapshot, reason)) {
        _dropPendingFeed();
        _install(snapshot);
      } else {
        _pending = snapshot;
        debugPrint('[FEED] rebuild held (${reason.name}) — offering it instead');
      }

      // Written from the SNAPSHOT, not from `_posts` — this page may have been
      // held back as `_pending` rather than installed, and the freshest full
      // page is still the right thing for the next cold start to open on.
      // Gated by the same default-page rule as _cachePostsIfDefault, keyed off
      // the identity this request was actually issued under.
      if (snapshot.posts.isNotEmpty && identity.queryKey == _defaultQueryKey) {
        await CacheService.savePosts(snapshot.posts);
      }
    } catch (e) {
      if (seq != _postsRequestSeq) return;
      // A background rebuild that fails is not the user's problem: they are
      // reading a perfectly good feed. Failure is reported only when nothing on
      // screen actually answers the question being asked — which includes the
      // case where a placeholder or another tab's page is showing, since neither
      // is an answer to this one.
      if (!_hasAnswerForCurrentQuery) {
        _errors.set(
            AppFeature.discover, ErrorMapper.toMessage(e, context: ErrorContext.loadFeed));
      }
      debugPrint('[AppProvider] loadPosts failed (${reason.name}): $e');
    } finally {
      // Only the newest request owns the loading flag: an outdated response
      // must not clear a spinner that belongs to a load still running.
      if (seq == _postsRequestSeq) {
        // Author avatars start caching with the feed so cards render them
        // instantly.
        _warmAvatarUrls(_posts.map((p) => p.authorAvatar));
        _isLoadingPosts = false;
        notifyListeners();
      }
    }
  }

  /// Whether [next] may replace what is on screen right now.
  ///
  /// Four ways to earn it, in the order they are checked:
  ///   1. nothing is on screen yet — there is nothing to disturb;
  ///   2. the user asked (refresh, filter, tab, account change, app upgrade);
  ///   3. Discover is not the visible tab — the swap is literally unseeable;
  ///   4. the new ranking does not visibly differ — installing it moves nothing,
  ///      so holding it back would only produce a prompt that does nothing.
  ///
  /// Rule 4 is what keeps the prompt honest. Most background rebuilds return
  /// the same order (the server's ranking clock is bucketed for exactly this
  /// reason), and a "New recommendations available" pill that reorders nothing
  /// teaches people to ignore it.
  bool _shouldInstall(FeedSnapshot next, FeedInvalidation reason) {
    final current = _installed;
    return FeedArrival.installs(
      hasVisibleFeed: current != null,
      visibleIsPlaceholder: current?.fromCache ?? false,
      readerEngaged: _readerEngaged,
      discoverVisible: _discoverVisible,
      reason: reason,
      gainsCoordinates: current != null &&
          !current.identity.hasCoordinates &&
          next.identity.hasCoordinates,
      differsVisibly: current != null && next.differsVisiblyFrom(current),
    );
  }

  /// Tell the provider whether the reader has scrolled away from the top of the
  /// feed. Driven by Discover's scroll controller.
  ///
  /// Nothing here re-ranks anything; it decides whether a ranking that has
  /// ALREADY been computed is allowed to land unannounced. See [_shouldInstall].
  void setFeedEngaged(bool engaged) {
    if (_readerEngaged == engaged) return;
    _readerEngaged = engaged;
    // Returning to the top is the moment a held-back rebuild becomes free to
    // show, but it still is not applied automatically — the prompt is already on
    // screen and it is the reader's to tap.
  }

  /// Keep [snapshot] for the question it answers, so coming back to that tab is
  /// instant. Placeholders are never remembered — a page read off the disk or
  /// filtered out of another tab is not an answer to anything.
  void _remember(FeedSnapshot snapshot) {
    if (snapshot.fromCache || snapshot.posts.isEmpty) return;
    final key = snapshot.identity.queryKey;
    _snapshotsByQuery.remove(key); // re-insert so iteration order is recency
    _snapshotsByQuery[key] = snapshot;
    while (_snapshotsByQuery.length > _rememberedQueries) {
      _snapshotsByQuery.remove(_snapshotsByQuery.keys.first);
    }
  }

  /// The remembered ranking for [identity], if it still answers that question.
  FeedSnapshot? _rememberedFor(FeedIdentity identity) {
    final snapshot = _snapshotsByQuery[identity.queryKey];
    if (snapshot == null) return null;
    if (!snapshot.identity.answersSameQuestionAs(identity)) {
      _snapshotsByQuery.remove(identity.queryKey);
      return null;
    }
    return snapshot;
  }

  /// The visible feed, re-scoped for [scope] — the instant stand-in for a tab
  /// that has never been fetched. See [FeedSnapshot.rescopedFor].
  ///
  /// This is exactly what [filteredPosts] has always rendered on a tab switch;
  /// the difference is that it now arrives as a SNAPSHOT, so Discover reads it
  /// as content instead of falling through to skeletons with an empty list.
  FeedSnapshot? _seedFor(FeedScope scope, FeedIdentity identity) =>
      (_installed ?? _snapshotsByQuery[_defaultQueryKey])
          ?.rescopedFor(scope, identity);

  /// Make [snapshot] the ranking on screen. The ONLY place `_posts` is
  /// wholesale replaced.
  void _install(FeedSnapshot snapshot) {
    _installed = snapshot;
    _posts = [...snapshot.posts];
    // A replacement, not an edit — Discover crossfades on this changing. Local
    // splices into `_posts` deliberately leave it alone so an optimistic insert
    // does not restart the list (and lose the reader's scroll position).
    _feedGeneration++;
    // A fresh page is a fresh impression session.
    InteractionTracker.instance.resetImpressions();
  }

  /// Discover tab → the one scope definition (engine parameter AND fallback
  /// filters). See utils/feed_scope.dart.
  FeedScope get _scopeForFilter => FeedScope.fromDiscoverFilter(_selectedFilter);

  /// Load jobs from Supabase.
  /// When offline: keeps cached _jobs, does not clear or show endless loading.
  ///
  /// [force] bypasses the identity gate for an explicit refresh. Without the
  /// gate, Jobs re-fetched and re-ordered for every GPS jitter update that
  /// reached [setViewer] — the same instability Discover had, on a tab nobody
  /// thought to look at.
  Future<void> loadJobs({bool force = false}) async {
    final identity = _identityFor(FeedScope.jobs, _currentFilters);
    if (!force &&
        _jobs.isNotEmpty &&
        _jobsIdentity != null &&
        _jobsIdentity!.invalidationFrom(identity).isNone) {
      return;
    }
    _jobsIdentity = identity;

    final seq = ++_jobsRequestSeq;
    // Only spin when there is nothing to look at. Cached jobs hydrated at
    // startup count as something: a refresh underneath them must not replace the
    // tab with skeletons.
    _isLoadingJobs = _jobs.isEmpty;
    _errors.clear(AppFeature.jobs);
    notifyListeners();

    try {
      // Splash-time prefetch (see loadPosts for the contract).
      final prefetch = StartupPrefetch.takeJobs();
      if (prefetch != null && !hasActiveFilters && _searchQuery.isEmpty) {
        final prefetched = await prefetch;
        if (prefetched != null) {
          _jobs = prefetched;
          _jobsResolved = true;
          _cacheJobsIfDefault();
          return;
        }
      }

      final results = await Connectivity().checkConnectivity();
      final offline = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
      if (offline) {
        final cached = await CacheService.loadJobs();
        if (cached.isNotEmpty) {
          _jobs = cached;
        }
        _isLoadingJobs = false;
        notifyListeners();
        return;
      }

      final filters = _currentFilters;
      // Jobs run through the SAME engine as Discover (scope=jobs). The tab
      // used to be a second, weaker copy of the feed query — same table,
      // narrower search, no ranking (audit §3.11). An electrician now sees
      // electrical jobs first here for the same reason they do in Discover.
      final result = await FeedService.fetchJobsFeed(
        userId: _viewerUserId,
        latitude: _viewerLatitude,
        longitude: _viewerLongitude,
        filters: filters,
      );
      if (seq != _jobsRequestSeq) return;

      _jobs = result.items;
      _jobsResolved = true;
      _cacheJobsIfDefault();
    } catch (e) {
      if (seq != _jobsRequestSeq) return;
      _errors.set(AppFeature.jobs, ErrorMapper.toMessage(e, context: ErrorContext.loadFeed));
      debugPrint('[AppProvider] loadJobs failed: $e');
    } finally {
      if (seq == _jobsRequestSeq) {
        _warmAvatarUrls(_jobs.map((j) => j.authorAvatarUrl));
        _isLoadingJobs = false;
        notifyListeners();
      }
    }
  }

  /// How many urgent requests one load fetches.
  ///
  /// ONE size for every caller. The Discover header used the default (5) and
  /// the Urgent screen asked for 20, and both wrote this same list — so the
  /// header's badge was showing a PAGE SIZE, not a count. With twelve urgent
  /// requests nearby it read 5, became 12 the moment you opened the screen, and
  /// dropped back to 5 on the next refresh. A number that changes because of
  /// where you navigated is worse than no number.
  ///
  /// 20 costs nothing in practice: the urgent window is one hour, so this list
  /// is almost always a handful of rows.
  static const int urgentPageSize = 20;


  /// Load urgent posts for top banner.
  /// Prioritization: urgent -> nearest first -> newest fallback.
  Future<void> loadUrgentPosts({
    double? userLatitude,
    double? userLongitude,
    int limit = urgentPageSize,
  }) async {
    _isLoadingUrgentPosts = true;
    _errors.clear(AppFeature.urgent);
    notifyListeners();
    try {
      // Splash-time prefetch (take-once; no filters apply to urgent posts).
      final prefetch = StartupPrefetch.takeUrgentPosts();
      if (prefetch != null) {
        final prefetched = await prefetch;
        if (prefetched != null) {
          _sortUrgentByProximity(prefetched, userLatitude, userLongitude);
          _urgentPosts = prefetched;
          return;
        }
      }

      final results = await Connectivity().checkConnectivity();
      final offline = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
      if (offline) {
        // Offline is not emptiness. This used to assign `const []`, which blanked
        // the Urgent screen and zeroed the Discover badge the instant signal
        // dropped — discarding data that was on screen a second earlier. The
        // last known requests stay; each card's own expiry filter removes any
        // whose window closes meanwhile, so nothing stale is ever actionable.
        return;
      }

      final fetched = await PostService.fetchUrgentPosts(limit: limit);
      _sortUrgentByProximity(fetched, userLatitude, userLongitude);
      _urgentPosts = fetched;
    } catch (e) {
      _errors.set(AppFeature.urgent, ErrorMapper.toMessage(e, context: ErrorContext.loadFeed));
      debugPrint('[AppProvider] loadUrgentPosts failed: $e');
    } finally {
      _warmAvatarUrls(_urgentPosts.map((p) => p.authorAvatar));
      _isLoadingUrgentPosts = false;
      notifyListeners();
    }
  }

  /// Urgent prioritization: nearest first (when both sides have coordinates),
  /// newest as tie-break and fallback. Extracted so the prefetch-consumption
  /// path applies the exact same ordering as a live fetch.
  void _sortUrgentByProximity(
    List<PostModel> posts,
    double? userLatitude,
    double? userLongitude,
  ) {
    posts.sort((a, b) {
      final aHasCoords = a.latitude != null && a.longitude != null && userLatitude != null && userLongitude != null;
      final bHasCoords = b.latitude != null && b.longitude != null && userLatitude != null && userLongitude != null;
      if (aHasCoords && bHasCoords) {
        final ad = distanceKm(userLatitude!, userLongitude!, a.latitude!, a.longitude!);
        final bd = distanceKm(userLatitude!, userLongitude!, b.latitude!, b.longitude!);
        final byDistance = ad.compareTo(bd);
        if (byDistance != 0) return byDistance;
        return b.createdAt.compareTo(a.createdAt);
      }
      if (aHasCoords != bHasCoords) return aHasCoords ? -1 : 1;
      return b.createdAt.compareTo(a.createdAt);
    });
  }

  /// Create a new post. Requires [currentUserId] (real user id from auth).
  Future<PostModel?> createPost(
    PostModel post, {
    required String? currentUserId,
    List<XFile>? imageFiles,
    void Function(int completed, int total)? onImageUploadProgress,
  }) async {
    _isPosting = true;
    _errors.clear(AppFeature.posting);
    notifyListeners();

    try {
      await AuthService.ensureCurrentUserInSupabase();
      final createdPost = await PostService.createPost(
        post,
        currentUserId: currentUserId,
        imageFiles: imageFiles,
        onImageUploadProgress: onImageUploadProgress,
      );

      // PostService returns a FEED-SHAPED post (author id, name, avatar,
      // reputation warmed, server timestamp), so this optimistic insert puts a
      // complete card at the top of Discover — correct owner badge, correct
      // CTA, no '?', no placeholder. Nothing further is fetched.
      //
      // Replace-if-present rather than blind insert: a concurrent loadPosts can
      // land the same row first, and two cards for one post is its own bug.
      final existing = _posts.indexWhere((p) => p.id == createdPost.id);
      if (existing != -1) {
        _posts[existing] = createdPost;
      } else {
        _posts.insert(0, createdPost);
      }
      _warmAvatarUrls([createdPost.authorAvatar]);
      _cachePostsIfDefault();
      // Emergency posts must surface in the Urgent section immediately.
      if (createdPost.isUrgent || createdPost.urgency == Urgency.urgent) {
        unawaited(loadUrgentPosts());
      }
      // The corpus changed, so the ranking is due — but quietly. The card above
      // is where the author expects to find what they just published, and a
      // rebuild would demote it (own posts score −25). Offered, not applied.
      unawaited(loadPosts(reason: FeedInvalidation.authored));
      notifyListeners();
      return createdPost;
    } catch (e) {
      _errors.set(AppFeature.posting, ErrorMapper.toMessage(e, context: ErrorContext.save));
      debugPrint('[AppProvider] createPost failed: $e');
      return null;
    } finally {
      _isPosting = false;
      notifyListeners();
    }
  }

  /// Create a new job. Requires [currentUserId].
  Future<JobModel?> createJob(
    JobModel job, {
    required String? currentUserId,
    List<XFile>? imageFiles,
    void Function(int completed, int total)? onImageUploadProgress,
  }) async {
    _isPosting = true;
    _errors.clear(AppFeature.posting);
    notifyListeners();

    try {
      await AuthService.ensureCurrentUserInSupabase();
      final createdJob = await PostService.createJob(
        job,
        currentUserId: currentUserId,
        imageFiles: imageFiles,
        onImageUploadProgress: onImageUploadProgress,
      );

      // Same contract as createPost above.
      final existing = _jobs.indexWhere((j) => j.id == createdJob.id);
      if (existing != -1) {
        _jobs[existing] = createdJob;
      } else {
        _jobs.insert(0, createdJob);
      }
      _warmAvatarUrls([createdJob.authorAvatarUrl]);
      _cacheJobsIfDefault();
      notifyListeners();
      return createdJob;
    } catch (e) {
      _errors.set(AppFeature.posting, ErrorMapper.toMessage(e, context: ErrorContext.save));
      debugPrint('[AppProvider] createJob failed: $e');
      return null;
    } finally {
      _isPosting = false;
      notifyListeners();
    }
  }

  /// Add post to local list (for optimistic updates)
  void addPost(PostModel post) {
    _posts.insert(0, post);
    notifyListeners();
  }

  /// Add job to local list (for optimistic updates)
  void addJob(JobModel job) {
    _jobs.insert(0, job);
    notifyListeners();
  }

  /// Delete a post or job. Only the author can delete. Removes from posts and jobs lists.
  Future<bool> deletePost(String postId, String? currentUserId) async {
    if (currentUserId == null || currentUserId.isEmpty) return false;
    String? authorId;
    if (_posts.any((p) => p.id == postId)) {
      authorId = _posts.firstWhere((p) => p.id == postId).authorUserId;
    } else if (_jobs.any((j) => j.id == postId)) {
      authorId = _jobs.firstWhere((j) => j.id == postId).authorUserId;
    }
    if (authorId == null || authorId != currentUserId) return false;
    try {
      // Soft delete / archive via the backend (policy-enforced; never hard-deletes,
      // so reviews, reputation, escrow, disputes and chat history are preserved).
      await JobsService.archivePost(postId: postId, userId: currentUserId);
      _posts.removeWhere((p) => p.id == postId);
      _jobs.removeWhere((j) => j.id == postId);
      _cachePostsIfDefault();
      _cacheJobsIfDefault();
      notifyListeners();
      return true;
    } on JobsException catch (e) {
      // Policy message (e.g. funds in escrow, active dispute) — surface to the user.
      _errors.set(AppFeature.posting, e.message);
      debugPrint('[ARCHIVE] blocked: ${e.message}');
      return false;
    } catch (e) {
      _errors.set(AppFeature.posting, 'Could not remove this post. Please try again.');
      debugPrint('[ARCHIVE] error: $e');
      return false;
    }
  }

  // NOTE: A direct "mark job completed" path was removed here (Sprint 1, Phase 1.2).
  // It wrote posts.status='completed' straight to the DB, bypassing escrow, payout
  // and notifications, which could desync job state from payment state. Completion
  // now flows exclusively through the backend escrow lifecycle:
  //   provider → POST /jobs/mark-complete  →  client → POST /jobs/approve.

  // ==================== APPLICATIONS ====================

  /// Load the set of posts the user has already applied to, so every card can
  /// show a stable "Applied / Offer sent" state that survives refresh. One
  /// query for all of them; safe to call repeatedly (idempotent). Clears on
  /// logout (empty [userId]).
  Future<void> loadMyApplications(String? userId) async {
    if (userId == null || userId.isEmpty) {
      if (_appliedPostIds.isNotEmpty) {
        _appliedPostIds = {};
        notifyListeners();
      }
      return;
    }
    try {
      final apps = await ApplicationService.getMyApplications(userId);
      _appliedPostIds = apps.map((a) => a.postId).where((id) => id.isNotEmpty).toSet();
      notifyListeners();
    } catch (e) {
      // Non-fatal: an unavailable applications query just leaves the last known
      // set in place (better than dropping every "Applied" badge on a blip).
      debugPrint('[AppProvider] loadMyApplications failed: $e');
    }
  }

  /// Record that the current user has just responded to [postId], so every
  /// card showing it flips to its done state without waiting for the next
  /// [loadMyApplications].
  ///
  /// Called by the ONE apply flow (`post_flows.applyToListing`). It replaced a
  /// pair of near-identical `submitApplicationToX` methods that each re-did the
  /// submission and its bookkeeping — the Jobs tab used one, nothing used the
  /// other, and the shared flow used neither.
  void markApplied(String postId) {
    if (postId.isEmpty || _appliedPostIds.contains(postId)) return;
    _appliedPostIds.add(postId);
    notifyListeners();
  }

  // submitApplicationToPost / submitApplicationToJob removed. They were two
  // copies of one submission — the Jobs tab called the second, nothing called
  // the first, and the shared apply flow called neither, which is how the job
  // path came to have an ownership story of its own. Submission now happens in
  // exactly one place (ApplicationService.submitApplication, reached only via
  // post_flows.applyToListing) and the applied state is recorded by
  // [markApplied] above.

  /// Legacy method for backward compatibility
  void addApplicationToPost(String postId, Application application) {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index != -1) {
      final post = _posts[index];
      final updatedApplications = [...post.applications, application];
      _posts[index] = post.copyWith(applications: updatedApplications);
      notifyListeners();
    }
  }

  /// Legacy method for backward compatibility
  void addApplicationToJob(String jobId, Application application) {
    final index = _jobs.indexWhere((j) => j.id == jobId);
    if (index != -1) {
      final job = _jobs[index];
      final updatedApplications = [...job.applications, application];
      _jobs[index] = job.copyWith(
        applications: updatedApplications,
        hasApplied: true,
      );
      notifyListeners();
    }
  }

  // ==================== CONVERSATIONS ====================

  /// Account that OWNS the conversations currently in [_conversations].
  ///
  /// Only ever changes when the signed-in account changes. It used to double as
  /// "is the stream running", and the offline path reset it to '' so a retry
  /// could get through — which meant the next call read "different account",
  /// wiped the list it had just hydrated from disk, and re-read it across an
  /// await. Any unrelated notifyListeners() landing in that window painted an
  /// empty Messages tab. The two questions are now two fields.
  String _conversationsUserId = '';

  /// Account the LIVE STREAM is subscribed for ('' = not subscribed).
  String _conversationsSubscribedUserId = '';

  /// Ids appended by [loadMoreConversations] — i.e. conversations that exist
  /// beyond the realtime stream's first page.
  ///
  /// This replaces a length comparison (`list + _conversations.sublist(...)`)
  /// that tried to infer "these are paginated extras" from list SIZE. When the
  /// incoming list belonged to a different, smaller account, that heuristic
  /// re-installed the previous user's conversations instead — the mechanism
  /// behind the cross-account leak. Tracking the ids we actually paginated
  /// makes the distinction explicit and account-safe: an id nobody paged in for
  /// THIS user can never be preserved.
  final Set<String> _pagedConversationIds = {};

  /// Real-time chat list from Supabase, designed so the Messages tab paints
  /// instantly:
  ///
  /// 1. Idempotent — the stream is started once (at app start / auth ready)
  ///    and survives tab switches. Re-entering the tab is a no-op instead of
  ///    a cancel-resubscribe-skeleton cycle.
  /// 2. Stale-while-revalidate — cached conversations hydrate the list
  ///    immediately (online too, not just offline); the live stream then
  ///    refreshes silently. The skeleton only ever shows on a true first run.
  /// 3. Avatars are pre-warmed into the image cache so tiles render without
  ///    pop-in.
  Future<void> loadConversations(String currentUserId) async {
    if (currentUserId.isEmpty) {
      resetForSignOut();
      return;
    }
    if (_conversationsSubscribedUserId == currentUserId &&
        _conversationStreamSubscription != null) {
      return; // Already syncing for this user — nothing to do.
    }
    // Switching users: drop the outgoing account's list BEFORE anything can
    // paint. Previously this was left in place and merged against, so the new
    // account inherited whatever the old one had.
    if (_conversationsUserId != currentUserId) {
      _conversations = [];
      _pagedConversationIds.clear();
    }
    _conversationsUserId = currentUserId;
    _errors.clear(AppFeature.messages);
    _hasMoreConversations = true;
    _conversationStreamSubscription?.cancel();
    _conversationStreamSubscription = null;

    // Disk hydration first: whatever we knew last session shows instantly.
    // Scoped to this uid, so the cache physically cannot hold another account's
    // conversations. The post-await re-check also confirms the user has not
    // changed again while the disk read was in flight.
    if (_conversations.isEmpty) {
      final cached = await CacheService.loadConversations(currentUserId);
      if (_conversationsUserId == currentUserId &&
          _conversations.isEmpty &&
          cached.isNotEmpty) {
        _conversations = cached;
        _warmAvatarCache(cached);
      }
    }
    _isLoadingConversations = _conversations.isEmpty;
    notifyListeners();

    final results = await Connectivity().checkConnectivity();
    final offline = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (offline) {
      _isLoadingConversations = false;
      // Not subscribed — a later call (tab tap, reconnect) retries. The OWNER
      // id stays put: the cached conversations hydrated above belong to this
      // account and must survive, which is the whole point of hydrating them.
      _conversationsSubscribedUserId = '';
      notifyListeners();
      return;
    }

    _conversationsSubscribedUserId = currentUserId;
    _conversationStreamSubscription = ChatServiceSupabase.watchConversations(currentUserId).listen(
      (list) {
        // A stream started for a previous user can still deliver after the
        // switch (cancel() does not retroactively drop an in-flight event).
        // Anything not addressed to the current session is discarded.
        if (_conversationsUserId != currentUserId) return;

        // The stream is authoritative for its page. Only conversations we
        // explicitly paginated in — for THIS user — are preserved beyond it.
        final incomingIds = list.map((c) => c.id).toSet();
        final pagedTail = _conversations
            .where((c) =>
                !incomingIds.contains(c.id) &&
                _pagedConversationIds.contains(c.id))
            .toList();
        _conversations = [...list, ...pagedTail];

        _isLoadingConversations = false;
        _errors.clear(AppFeature.messages);
        // Written unconditionally, including an empty list: "this account has
        // no conversations" is a fact worth persisting. Skipping the write for
        // empty results is what let one account's cached list outlive it and
        // surface under the next.
        //
        // This is only safe because the stream no longer publishes a failed
        // fetch as an empty list (see watchConversations): every `list` that
        // reaches here is an answer from the server, so persisting an empty one
        // records a fact rather than overwriting history with an outage.
        CacheService.saveConversations(currentUserId, list);
        if (list.isNotEmpty) _warmAvatarCache(list);
        notifyListeners();
      },
      onError: (e) {
        if (_conversationsUserId != currentUserId) return;
        // Reached only before the first successful load — the stream withholds
        // later failures rather than emitting them, so a blip can never clear
        // conversations that are already on screen.
        _errors.set(AppFeature.messages,
            ErrorMapper.toMessage(e, context: ErrorContext.loadContent));
        _isLoadingConversations = false;
        notifyListeners();
      },
    );
  }

  void stopListeningToConversations() {
    _conversationStreamSubscription?.cancel();
    _conversationStreamSubscription = null;
    // Stops the SYNC, not the ownership: the list stays readable and stays
    // attributed to the account it belongs to.
    _conversationsSubscribedUserId = '';
  }

  @override
  void dispose() {
    SessionScope.instance.unregister(this);
    _conversationStreamSubscription?.cancel();
    _searchDebounce?.cancel();
    _viewerGraceTimer?.cancel();
    super.dispose();
  }

  /// URLs already fed to the image cache this session (avoid re-resolving).
  final Set<String> _warmedAvatarUrls = {};

  /// Kick off avatar downloads into cached_network_image's cache the moment
  /// data mentioning them lands (feed, jobs, conversations) — avatars are
  /// then already decoded when their card/tile builds, so they are never
  /// seen loading. Fire-and-forget; errors are swallowed by the pipeline.
  void _warmAvatarUrls(Iterable<String> urls, {int cap = 40}) {
    var started = 0;
    for (final url in urls) {
      if (started >= cap) break;
      if (url.isEmpty || !_warmedAvatarUrls.add(url)) continue;
      started++;
      try {
        CachedNetworkImageProvider(url).resolve(ImageConfiguration.empty);
      } catch (_) {
        // Never let a bad URL disturb the provider.
      }
    }
  }

  void _warmAvatarCache(List<Conversation> list) =>
      _warmAvatarUrls(list.take(30).map((c) => c.userAvatar));

  bool _hasMoreConversations = true;
  bool _loadingMoreConversations = false;

  bool get hasMoreConversations => _hasMoreConversations;
  bool get loadingMoreConversations => _loadingMoreConversations;

  /// Sum of unread messages across all conversations.
  int get totalUnreadCount =>
      _conversations.fold(0, (sum, c) => sum + c.unreadCount);

  /// Repaint conversation consumers after device-local state changed
  /// (e.g. clear-conversation watermark, mute toggles) — the data the tiles
  /// read lives in ChatLocalPrefs, not in this provider.
  void touchConversations() => notifyListeners();

  /// Instantly zero the local unread badge for a chat the user just opened.
  /// The DB reset happens in ChatServiceSupabase.markMessagesSeen().
  void markConversationRead(String chatId) {
    final idx = _conversations.indexWhere((c) => c.id == chatId);
    if (idx == -1 || _conversations[idx].unreadCount == 0) return;
    _conversations[idx] = _conversations[idx].copyWith(unreadCount: 0);
    notifyListeners();
  }

  // ── Active chat tracking (for notification suppression) ──────────────────
  String? _activeChatId;
  String? get activeChatId => _activeChatId;

  /// Called by ChatScreen on open/close so foreground FCM for the current
  /// chat is suppressed (the user already sees the messages).
  void setActiveChatId(String? chatId) {
    _activeChatId = chatId;
    // No notifyListeners() — this is only read by the FCM handler.
  }

  /// Load next page of conversations (lazy load). Call when user scrolls near bottom.
  Future<void> loadMoreConversations(String currentUserId) async {
    if (currentUserId.isEmpty || !_hasMoreConversations || _isLoadingConversations || _loadingMoreConversations) return;
    if (_conversationsUserId != currentUserId) return;
    _loadingMoreConversations = true;
    notifyListeners();
    try {
      final result = await ChatServiceSupabase.getConversationsPage(
        currentUserId,
        offset: _conversations.length,
      );
      // The page was requested for a user who may have signed out while it was
      // in flight; appending it now would repopulate a cleared list.
      if (_conversationsUserId != currentUserId) return;
      if (result.list.isEmpty) {
        _hasMoreConversations = false;
      } else {
        final existingIds = _conversations.map((c) => c.id).toSet();
        final newList = result.list.where((c) => !existingIds.contains(c.id)).toList();
        _conversations = _conversations + newList;
        // Remember these so a later realtime emission (which only covers page
        // one) does not drop them.
        _pagedConversationIds.addAll(newList.map((c) => c.id));
        _hasMoreConversations = result.hasMore;
      }
      notifyListeners();
    } catch (e) {
      _hasMoreConversations = false;
      notifyListeners();
    } finally {
      _loadingMoreConversations = false;
      notifyListeners();
    }
  }

  // ensureConversationOnApply removed. It had NO callers — chats are created on
  // first send, by ChatScreen, through ChatServiceSupabase.createChat (see the
  // pending-Conversation pattern in post_flows). Its only live effect was to
  // write the shared error slot from a Messages-shaped failure, which the
  // Discover feed could then render as its own. Dead code that could only cause
  // contamination.

  /// Update a conversation in the local list
  void updateConversation(Conversation conversation) {
    final index = _conversations.indexWhere((c) => c.id == conversation.id);
    if (index != -1) {
      _conversations[index] = conversation;
    } else {
      _conversations.insert(0, conversation);
    }
    notifyListeners();
  }

  // ==================== THEME ====================

  /// SharedPreferences key holding a [ThemePreference.storageKey].
  static const String themePrefsKey = 'themeMode';

  /// Legacy boolean key (pre-Theme milestone). Read once at startup and
  /// migrated to [themePrefsKey]; never written again.
  static const String legacyThemePrefsKey = 'isDarkMode';

  void setThemePreference(ThemePreference preference) {
    if (_themePreference == preference) return;
    _themePreference = preference;
    notifyListeners();
    // Persist immediately; fire-and-forget (non-blocking).
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString(themePrefsKey, preference.storageKey),
    );
  }

  /// Resolve the startup theme, migrating the legacy boolean exactly once.
  ///
  /// Migration rule — chosen so NO existing user is flipped:
  ///   * `themeMode` present  → the user has already used the new picker.
  ///   * `isDarkMode` present → they explicitly toggled the old switch, so
  ///     that choice is preserved as an EXPLICIT Light/Dark (not "system",
  ///     which could visibly change their app on first launch).
  ///   * neither present      → Device Default, the new default.
  static Future<ThemePreference> loadThemePreference(SharedPreferences prefs) async {
    final stored = prefs.getString(themePrefsKey);
    if (stored != null) return ThemePreference.fromStorage(stored);

    if (prefs.containsKey(legacyThemePrefsKey)) {
      final wasDark = prefs.getBool(legacyThemePrefsKey) ?? true;
      final migrated = wasDark ? ThemePreference.dark : ThemePreference.light;
      await prefs.setString(themePrefsKey, migrated.storageKey);
      return migrated;
    }
    return ThemePreference.system;
  }

  // ==================== FILTERS ====================

  /// Update the search box.
  ///
  /// Debounced: this used to fire a FULL feed query — 50 rows with joined
  /// users, images and every applicant — on every single keystroke, unthrottled
  /// and unsequenced (audit §3.7). Typing "electrician" cost eleven of them.
  /// The text still updates instantly (the client-side filter in
  /// [filteredPosts] keeps the list responsive); only the network call waits.
  ///
  /// Set [submitted] when the user actually commits the search — that, and
  /// only that, is recorded as a behavioural signal. Prefixes like "electr"
  /// are not things anyone searched for, and storing them would fill the
  /// affinity table with fragments.
  void setSearchQuery(String query, {bool submitted = false}) {
    _searchQuery = query;
    notifyListeners();

    _searchDebounce?.cancel();
    if (submitted) {
      InteractionTracker.instance.trackSearch(query);
      loadPosts(reason: FeedInvalidation.query);
      return;
    }
    _searchDebounce =
        Timer(_searchDebounceDelay, () => loadPosts(reason: FeedInvalidation.query));
  }

  /// Switch tabs — and show that tab's posts in the same frame.
  ///
  /// WHY THIS IS NOT JUST A RELOAD
  /// -----------------------------
  /// Tapping Requests used to mean: change the question, discover that nothing
  /// on screen answers it, fall through to skeletons, and wait for a round trip.
  /// The ranking for that tab was usually seconds old and perfectly good — the
  /// app had simply thrown it away when the user left. Shimmer on a healthy
  /// connection is a rendering of that decision, not of the network.
  ///
  /// Three ways to fill the tab, in order of how good the answer is:
  ///   1. the ranking we already have for exactly this question — install it,
  ///      and rebuild in the background only once it is past its TTL;
  ///   2. the visible page, re-scoped — a placeholder, replaced by the real
  ///      scoped page the moment it lands;
  ///   3. nothing to show: skeletons, as before.
  void setSelectedFilter(String filter) {
    if (_selectedFilter != filter) _dropPendingFeed();
    _selectedFilter = filter;
    // An explicit reload supersedes a pending debounced one. Switching tabs
    // clears the search box first, so without this the tab's own load would be
    // followed 350 ms later by an identical duplicate.
    _searchDebounce?.cancel();

    final scope = _scopeForFilter;
    final identity = _identityFor(scope, _currentFilters);
    final remembered = _rememberedFor(identity);
    if (remembered != null) {
      // Nothing is fetched on this path, so the sequence has to be advanced by
      // hand: a load still in flight for the tab we just left would otherwise
      // pass its own freshness check and install the PREVIOUS tab's page over
      // this one.
      ++_postsRequestSeq;
      _isLoadingPosts = false;
      _install(remembered);
      notifyListeners();
      // Fresh enough to be the answer, so nothing else is asked for. A page
      // older than the server's own ranking bucket is rebuilt quietly and
      // OFFERED — the user asked to see this tab, not to have it re-sorted a
      // second after it appeared.
      if (remembered.isExpiredAt(DateTime.now())) {
        unawaited(loadPosts(reason: FeedInvalidation.expired));
      }
      return;
    }

    final seed = _seedFor(scope, identity);
    if (seed != null) _install(seed);
    notifyListeners();
    loadPosts(reason: FeedInvalidation.query);
  }

  void toggleCategory(String category) {
    if (_selectedCategories.contains(category)) {
      _selectedCategories.remove(category);
    } else {
      _selectedCategories.add(category);
      // Choosing a category is one of the clearest statements of intent the
      // app receives — ranking signal 9 reads it back as category affinity.
      InteractionTracker.instance.trackCategoryOpen(category);
    }
    notifyListeners();
  }

  void setCity(String city) {
    _selectedCity = city;
    _selectedArea = '';
    notifyListeners();
  }

  void setArea(String area) {
    _selectedArea = area;
    notifyListeners();
  }

  void setPriceRange(RangeValues range) {
    _priceRange = range;
    notifyListeners();
  }

  void setDifficulty(Difficulty? difficulty) {
    _selectedDifficulty = difficulty;
    notifyListeners();
  }

  void setUrgency(Urgency? urgency) {
    _selectedUrgency = urgency;
    notifyListeners();
  }

  void clearFilters() {
    _selectedCategories = {};
    _selectedCity = '';
    _selectedArea = '';
    _priceRange = const RangeValues(0, 100000);
    _selectedDifficulty = null;
    _selectedUrgency = null;
    notifyListeners();
    _searchDebounce?.cancel();
    loadPosts(reason: FeedInvalidation.query);
  }

  /// Tell the recommendation engine who is looking and from where.
  ///
  /// This replaces `setPriorityLocationCity`, which stored a city name that
  /// nothing ever read. Ranking uses real coordinates: distance is measured,
  /// not inferred from whether two location strings happen to share a word.
  ///
  /// Reloads the feed only when something material actually changed.
  ///
  /// "Material" used to mean `latitude != _viewerLatitude` — a raw double
  /// comparison, on a value the GPS revises by a few metres every time anything
  /// asks for it. Every one of those revisions cost a full Discover reload AND
  /// a full Jobs reload, and each reload re-sorted the cards on screen. Standing
  /// still was enough to make the feed churn.
  ///
  /// Significance is now a real distance ([FeedIdentity.significantMoveKm]), and
  /// an account change is handled differently from a move: signing in replaces
  /// the feed (it belongs to someone else now), while walking a kilometre offers
  /// a rebuild rather than performing one.
  void setViewer({String? userId, double? latitude, double? longitude}) {
    final nextUserId = (userId?.trim().isEmpty ?? true) ? null : userId!.trim();
    final firstResolution = !_viewerResolved;

    final before = FeedIdentity(
      userId: _viewerUserId,
      latitude: _viewerLatitude,
      longitude: _viewerLongitude,
      profileRevision: _profileRevision,
    );
    final after = FeedIdentity(
      userId: nextUserId,
      latitude: latitude,
      longitude: longitude,
      profileRevision: _profileRevision,
    );
    final reason = before.invalidationFrom(after);

    _viewerUserId = nextUserId;
    _viewerLatitude = latitude;
    _viewerLongitude = longitude;
    InteractionTracker.instance.setUser(nextUserId);

    // The identity has now been heard from, whoever it turned out to be. This
    // releases the first ranking, which deliberately waited so it could be
    // computed for the right person the first time.
    if (firstResolution) {
      _viewerResolved = true;
      _viewerGraceTimer?.cancel();
      _viewerGraceTimer = null;
      notifyListeners();
      // The launch ranking already went out for exactly this person, from
      // exactly this position, before the first frame — its answer is on its
      // way. Asking again would fetch the same page and then install it over
      // the one that arrives first, which is a reshuffle produced by nothing
      // but duplicate work.
      if (StartupPrefetch.answers(
        userId: nextUserId,
        latitude: latitude,
        longitude: longitude,
      )) {
        debugPrint('[FEED] viewer resolved — launch ranking already answers it');
        return;
      }
      unawaited(loadPosts(reason: FeedInvalidation.explicit));
      unawaited(loadJobs(force: true));
      return;
    }

    if (reason.isNone) return;
    notifyListeners();
    // A sign-in/sign-out replaces the feed; a move offers one. loadPosts reads
    // the reason and decides — see _shouldInstall.
    unawaited(loadPosts(reason: reason));
    unawaited(loadJobs());
  }

  /// Apply current filters and reload posts
  Future<void> applyFilters() async {
    _searchDebounce?.cancel();
    await loadPosts(reason: FeedInvalidation.query);
  }

  bool get hasActiveFilters {
    return _selectedCategories.isNotEmpty ||
        _selectedCity.isNotEmpty ||
        _selectedArea.isNotEmpty ||
        _selectedDifficulty != null ||
        _selectedUrgency != null ||
        _priceRange.start > 0 ||
        _priceRange.end < 100000;
  }

  /// Get filtered posts (local filtering for instant UI)
  List<PostModel> get filteredPosts {
    final filtered = _posts.where((post) {
      // Search query filter (also done server-side, but good for instant UI)
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        if (!post.title.toLowerCase().contains(query) &&
            !post.description.toLowerCase().contains(query) &&
            !post.category.name.toLowerCase().contains(query) &&
            !post.location.toLowerCase().contains(query)) {
          return false;
        }
      }

      // Type filter — the SAME scope the server query used, so the instant
      // client-side filter can never disagree with the page it is filtering.
      // This was a hand-written pair of tab comparisons that (like the old
      // fallback query) let job posts through on the "All" tab.
      if (!_scopeForFilter.postTypes.contains(post.type.name)) return false;

      // Status is deliberately NOT filtered here, though the QUERY filters it.
      // The query decides what enters the feed; this decides what stays visible
      // while the user looks at it. A listing that gets assigned mid-scroll must
      // render its "In Progress" badge — vanishing under the reader's thumb is
      // the worse behaviour, and openPostFromFeed already answers a closed
      // listing in place.

      // Category filter
      if (_selectedCategories.isNotEmpty &&
          !_selectedCategories.contains(post.category.name)) {
        return false;
      }

      // Location filter
      if (_selectedCity.isNotEmpty &&
          !post.location.toLowerCase().contains(_selectedCity.toLowerCase())) {
        return false;
      }
      if (_selectedArea.isNotEmpty &&
          !post.location.toLowerCase().contains(_selectedArea.toLowerCase())) {
        return false;
      }

      // Price filter — applied ONLY when the slider has actually been moved,
      // which is what the server does. Applying it unconditionally meant a
      // post priced 0 ("negotiable") was returned by the query and then hidden
      // by the client the moment the minimum was above zero: a post that
      // existed, matched, and was invisible (audit §3.5).
      if (_priceRange.start > 0 && post.price < _priceRange.start) return false;
      if (_priceRange.end < 100000 && post.price > _priceRange.end) return false;

      // Difficulty filter
      if (_selectedDifficulty != null && post.difficulty != _selectedDifficulty) {
        return false;
      }

      // Urgency filter
      if (_selectedUrgency != null && post.urgency != _selectedUrgency) {
        return false;
      }

      // Rating filter REMOVED (Phase 3.2C): PostModel.rating was fabricated and is
      // no longer a trust source. Reputation is per-provider and served by the
      // backend, so a min-rating filter would need a server-side query (future
      // work) — it can't be applied synchronously against a fake post field.

      return true;
    }).toList();

    return filtered;
  }

  /// Dismiss [feature]'s error.
  ///
  /// Replaces a no-argument `clearError()` that wiped the one shared slot —
  /// which had no callers, and could not have had a correct one: "clear the
  /// error" is unanswerable when five features share the field. Clearing is now
  /// something a feature does to its own state.
  void clearError(AppFeature feature) {
    if (_errors.clear(feature)) notifyListeners();
  }

  // _distanceKm / _degToRad removed: the same haversine was written twice by
  // hand — here, to sort urgent posts, and again in UrgentRequestsScreen to
  // label them. It now lives once in utils/proximity.dart, where it is also
  // unit-testable.
}
