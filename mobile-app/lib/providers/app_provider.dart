import 'dart:async';
import 'dart:math' as math;
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
import '../services/interaction_tracker.dart';
import '../services/jobs_service.dart';
import '../services/session_scope.dart';
import '../services/startup_prefetch.dart';
import '../services/supabase_auth_bridge.dart';
import '../utils/error_mapper.dart';

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
  String? _error;
  
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

  /// Where the current feed page came from, and why each post is where it is.
  /// `feedSignals` is a debugging surface — no layout depends on it.
  FeedSource _feedSource = FeedSource.fallback;
  Map<String, double> _feedScores = const {};
  Map<String, List<FeedSignalBreakdown>> _feedSignals = const {};
  bool _feedPersonalised = false;

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
  String? get error => _error;
  String get searchQuery => _searchQuery;
  String get selectedFilter => _selectedFilter;
  Set<String> get selectedCategories => _selectedCategories;
  String get selectedCity => _selectedCity;
  String get selectedArea => _selectedArea;
  RangeValues get priceRange => _priceRange;
  Difficulty? get selectedDifficulty => _selectedDifficulty;
  Urgency? get selectedUrgency => _selectedUrgency;

  /// True when the last page came from the ranking engine rather than the
  /// chronological fallback.
  bool get isFeedRanked => _feedSource == FeedSource.ranked;

  /// True when the server had enough about this viewer to personalise.
  bool get isFeedPersonalised => _feedPersonalised;

  /// Final recommendation score for [postId], when the page was ranked.
  double? feedScoreFor(String postId) => _feedScores[postId];

  /// Per-signal breakdown for [postId] — "Distance +28.4, Profession +25.0".
  /// Explainability surface for debugging and weight tuning.
  List<FeedSignalBreakdown> feedSignalsFor(String postId) =>
      _feedSignals[postId] ?? const [];

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
    _conversations = [];
    _pagedConversationIds.clear();
    _hasMoreConversations = true;
    _isLoadingConversations = false;
    _loadingMoreConversations = false;
    _appliedPostIds = {};
    _activeChatId = null;
    _warmedAvatarUrls.clear();
    _error = null;
    // Personalisation is per-account: the outgoing user's profession, affinity
    // and queued behavioural events must not follow them out. Posts stay (they
    // are public marketplace data) but the ranking that shaped them does not.
    _viewerUserId = null;
    _viewerLatitude = null;
    _viewerLongitude = null;
    _feedScores = const {};
    _feedSignals = const {};
    _feedPersonalised = false;
    InteractionTracker.instance.setUser(null);
    notifyListeners();
  }

  /// Load initial data from Supabase (conversations loaded when Messages screen opens with user id)
  Future<void> _loadInitialData() async {
    await Future.wait([
      loadPosts(),
      loadJobs(),
      // Keeps the Discover header's Urgent count live across refresh/reconnect.
      loadUrgentPosts(),
    ]);
  }

  /// Refresh all data
  Future<void> refreshAll() async {
    await _loadInitialData();
  }

  // ==================== POSTS ====================

  /// Load posts from Supabase with current filters.
  /// When offline: keeps cached _posts, does not clear or show endless loading.
  Future<void> loadPosts() async {
    final seq = ++_postsRequestSeq;
    _isLoadingPosts = true;
    _error = null;
    notifyListeners();

    try {
      // Consume the splash-time prefetch (take-once; null after startup).
      // Only usable while filter state is still at its startup defaults —
      // the prefetch mirrored exactly that query. On prefetch failure the
      // future resolves null and the unchanged path below takes over.
      final prefetch = StartupPrefetch.takePosts();
      if (prefetch != null &&
          !hasActiveFilters &&
          _searchQuery.isEmpty &&
          _selectedFilter == 'All') {
        final prefetched = await prefetch;
        if (prefetched != null) {
          _posts = prefetched;
          _feedSource = FeedSource.fallback; // prefetch is chronological
          if (_posts.isNotEmpty) {
            await CacheService.savePosts(_posts);
          }
          // Paint instantly from the prefetch, then RANK. Without this second
          // pass a cold start would leave the reader on chronological posts
          // until they pulled to refresh — and a signed-out browser, whose
          // setViewer call is a no-op (nothing changed), would never rank at
          // all. The prefetch is take-once, so this cannot recurse.
          unawaited(Future.microtask(loadPosts));
          return;
        }
      }

      final results = await Connectivity().checkConnectivity();
      final offline = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
      if (offline) {
        final cached = await CacheService.loadPosts();
        if (cached.isNotEmpty) {
          _posts = cached;
        }
        _isLoadingPosts = false;
        notifyListeners();
        return;
      }

      String? typeFilter;
      if (_selectedFilter == 'Requests') {
        typeFilter = 'request';
      } else if (_selectedFilter == 'Offers') {
        typeFilter = 'offer';
      }

      final filters = PostFilters(
        searchQuery: _searchQuery.isNotEmpty ? _searchQuery : null,
        categories: _selectedCategories.isNotEmpty ? _selectedCategories.toList() : null,
        city: _selectedCity.isNotEmpty ? _selectedCity : null,
        area: _selectedArea.isNotEmpty ? _selectedArea : null,
        type: typeFilter,
        urgency: _selectedUrgency?.name,
        minPrice: _priceRange.start > 0 ? _priceRange.start : null,
        maxPrice: _priceRange.end < 100000 ? _priceRange.end : null,
        difficulty: _selectedDifficulty?.name,
      );

      // The ranked feed. On any failure — cold backend, timeout, 5xx — this
      // degrades inside FeedService to the exact `created_at DESC` Supabase
      // query the app used before the engine existed, so ranking can never be
      // the reason Discover is empty.
      final result = await FeedService.fetchFeed(
        userId: _viewerUserId,
        latitude: _viewerLatitude,
        longitude: _viewerLongitude,
        scope: _scopeForFilter,
        filters: filters,
      );

      // A newer load started while this one was in flight — drop it rather than
      // letting a stale page overwrite a fresh one.
      if (seq != _postsRequestSeq) return;

      _posts = result.items;
      _feedSource = result.source;
      _feedScores = result.scores;
      _feedSignals = result.signals;
      _feedPersonalised = result.personalised;
      // A fresh page is a fresh impression session.
      InteractionTracker.instance.resetImpressions();
      if (_posts.isNotEmpty) {
        await CacheService.savePosts(_posts);
      }
    } catch (e) {
      if (seq != _postsRequestSeq) return;
      _error = ErrorMapper.toMessage(e, context: ErrorContext.loadFeed);
      debugPrint('[AppProvider] loadPosts failed: $e');
    } finally {
      // Only the newest request owns the loading flag: an outdated response
      // must not clear a spinner that belongs to a load still running.
      if (seq == _postsRequestSeq) {
        // Runs on every exit path (prefetch, offline cache, network): author
        // avatars start caching with the feed so cards render them instantly.
        _warmAvatarUrls(_posts.map((p) => p.authorAvatar));
        _isLoadingPosts = false;
        notifyListeners();
      }
    }
  }

  /// Discover tab → the ranking engine's scope parameter.
  String get _scopeForFilter => switch (_selectedFilter) {
        'Requests' => 'requests',
        'Offers' => 'offers',
        _ => 'all',
      };

  /// Load jobs from Supabase.
  /// When offline: keeps cached _jobs, does not clear or show endless loading.
  Future<void> loadJobs() async {
    final seq = ++_jobsRequestSeq;
    _isLoadingJobs = true;
    _error = null;
    notifyListeners();

    try {
      // Splash-time prefetch (see loadPosts for the contract).
      final prefetch = StartupPrefetch.takeJobs();
      if (prefetch != null && !hasActiveFilters && _searchQuery.isEmpty) {
        final prefetched = await prefetch;
        if (prefetched != null) {
          _jobs = prefetched;
          if (_jobs.isNotEmpty) {
            await CacheService.saveJobs(_jobs);
          }
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

      final filters = PostFilters(
        searchQuery: _searchQuery.isNotEmpty ? _searchQuery : null,
        categories: _selectedCategories.isNotEmpty ? _selectedCategories.toList() : null,
        city: _selectedCity.isNotEmpty ? _selectedCity : null,
        area: _selectedArea.isNotEmpty ? _selectedArea : null,
        type: 'job',
        urgency: _selectedUrgency?.name,
        minPrice: _priceRange.start > 0 ? _priceRange.start : null,
        maxPrice: _priceRange.end < 100000 ? _priceRange.end : null,
        difficulty: _selectedDifficulty?.name,
      );
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
      if (_jobs.isNotEmpty) {
        await CacheService.saveJobs(_jobs);
      }
    } catch (e) {
      if (seq != _jobsRequestSeq) return;
      _error = ErrorMapper.toMessage(e, context: ErrorContext.loadFeed);
      debugPrint('[AppProvider] loadJobs failed: $e');
    } finally {
      if (seq == _jobsRequestSeq) {
        _warmAvatarUrls(_jobs.map((j) => j.authorAvatarUrl));
        _isLoadingJobs = false;
        notifyListeners();
      }
    }
  }

  /// Load urgent posts for top banner.
  /// Prioritization: urgent -> nearest first -> newest fallback.
  Future<void> loadUrgentPosts({
    double? userLatitude,
    double? userLongitude,
    int limit = 5,
  }) async {
    _isLoadingUrgentPosts = true;
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
        _urgentPosts = const [];
        return;
      }

      final fetched = await PostService.fetchUrgentPosts(limit: limit);
      _sortUrgentByProximity(fetched, userLatitude, userLongitude);
      _urgentPosts = fetched;
    } catch (e) {
      _error = ErrorMapper.toMessage(e, context: ErrorContext.loadFeed);
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
        final ad = _distanceKm(userLatitude!, userLongitude!, a.latitude!, a.longitude!);
        final bd = _distanceKm(userLatitude!, userLongitude!, b.latitude!, b.longitude!);
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
    _error = null;
    notifyListeners();

    try {
      await AuthService.ensureCurrentUserInSupabase();
      final createdPost = await PostService.createPost(
        post,
        currentUserId: currentUserId,
        imageFiles: imageFiles,
        onImageUploadProgress: onImageUploadProgress,
      );

      _posts.insert(0, createdPost);
      if (_posts.isNotEmpty) {
        CacheService.savePosts(_posts);
      }
      // Emergency posts must surface in the Urgent section immediately.
      if (createdPost.isUrgent || createdPost.urgency == Urgency.urgent) {
        unawaited(loadUrgentPosts());
      }
      notifyListeners();
      return createdPost;
    } catch (e) {
      _error = ErrorMapper.toMessage(e, context: ErrorContext.save);
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
    _error = null;
    notifyListeners();

    try {
      await AuthService.ensureCurrentUserInSupabase();
      final createdJob = await PostService.createJob(
        job,
        currentUserId: currentUserId,
        imageFiles: imageFiles,
        onImageUploadProgress: onImageUploadProgress,
      );

      _jobs.insert(0, createdJob);
      if (_jobs.isNotEmpty) {
        CacheService.saveJobs(_jobs);
      }
      notifyListeners();
      return createdJob;
    } catch (e) {
      _error = ErrorMapper.toMessage(e, context: ErrorContext.save);
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
      if (_posts.isNotEmpty) CacheService.savePosts(_posts);
      if (_jobs.isNotEmpty) CacheService.saveJobs(_jobs);
      notifyListeners();
      return true;
    } on JobsException catch (e) {
      // Policy message (e.g. funds in escrow, active dispute) — surface to the user.
      _error = e.message;
      debugPrint('[ARCHIVE] blocked: ${e.message}');
      return false;
    } catch (e) {
      _error = 'Could not remove this post. Please try again.';
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

  /// User id the active conversation stream belongs to ('' = none).
  String _conversationsUserId = '';

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
    if (_conversationsUserId == currentUserId &&
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
    _error = null;
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
      // Allow a later call (tab tap / reconnect) to retry the subscription.
      _conversationsUserId = '';
      notifyListeners();
      return;
    }

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
        // Written unconditionally, including an empty list: "this account has
        // no conversations" is a fact worth persisting. Skipping the write for
        // empty results is what let one account's cached list outlive it and
        // surface under the next.
        CacheService.saveConversations(currentUserId, list);
        if (list.isNotEmpty) _warmAvatarCache(list);
        notifyListeners();
      },
      onError: (e) {
        if (_conversationsUserId != currentUserId) return;
        _error = ErrorMapper.toMessage(e, context: ErrorContext.loadContent);
        _isLoadingConversations = false;
        notifyListeners();
      },
    );
  }

  void stopListeningToConversations() {
    _conversationStreamSubscription?.cancel();
    _conversationStreamSubscription = null;
    _conversationsUserId = '';
  }

  @override
  void dispose() {
    SessionScope.instance.unregister(this);
    _conversationStreamSubscription?.cancel();
    _searchDebounce?.cancel();
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

  /// Create or get chat when user contacts provider (Firestore only). Chat appears in Messages tab.
  /// Pass [postId] from Discover or [jobId] from Jobs so each post/job has its own chat (no reused chats).
  Future<Conversation?> ensureConversationOnApply({
    required String applicantId,
    required String authorId,
    String initialMessage = '',
    String? postId,
    String? jobId,
  }) async {
    if (applicantId.isEmpty || authorId.isEmpty) return null;
    try {
      await SupabaseAuthBridge.ensureSessionForWriteAsync();
      final conv = await ChatServiceSupabase.createChat(
        user1Id: applicantId,
        user2Id: authorId,
        currentUserId: applicantId,
        initialMessage: initialMessage,
        postId: postId,
        jobId: jobId,
      );
      updateConversation(conv);
      return conv;
    } catch (e) {
      _error = ErrorMapper.toMessage(e, context: ErrorContext.loadContent);
      debugPrint('[AppProvider] createConversation failed: $e');
      return null;
    }
  }

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
      loadPosts();
      return;
    }
    _searchDebounce = Timer(_searchDebounceDelay, loadPosts);
  }

  void setSelectedFilter(String filter) {
    _selectedFilter = filter;
    notifyListeners();
    // An explicit reload supersedes a pending debounced one. Switching tabs
    // clears the search box first, so without this the tab's own load would be
    // followed 350 ms later by an identical duplicate.
    _searchDebounce?.cancel();
    loadPosts();
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
    loadPosts();
  }

  /// Tell the recommendation engine who is looking and from where.
  ///
  /// This replaces `setPriorityLocationCity`, which stored a city name that
  /// nothing ever read. Ranking uses real coordinates: distance is measured,
  /// not inferred from whether two location strings happen to share a word.
  ///
  /// Reloads the feed only when something material actually changed, so the
  /// presence heartbeat and lifecycle callbacks that call this on every resume
  /// do not each cost a feed query.
  void setViewer({String? userId, double? latitude, double? longitude}) {
    final nextUserId = (userId?.trim().isEmpty ?? true) ? null : userId!.trim();
    final changed = nextUserId != _viewerUserId ||
        latitude != _viewerLatitude ||
        longitude != _viewerLongitude;
    if (!changed) return;

    _viewerUserId = nextUserId;
    _viewerLatitude = latitude;
    _viewerLongitude = longitude;
    InteractionTracker.instance.setUser(nextUserId);
    notifyListeners();
    loadPosts();
    loadJobs();
  }

  /// Apply current filters and reload posts
  Future<void> applyFilters() async {
    _searchDebounce?.cancel();
    await loadPosts();
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

      // Type filter
      if (_selectedFilter == 'Requests' && post.type != PostType.request) {
        return false;
      }
      if (_selectedFilter == 'Offers' && post.type != PostType.offer) {
        return false;
      }

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

  /// Clear error message
  void clearError() {
    _error = null;
    notifyListeners();
  }

  static double _distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusKm = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) * math.cos(_degToRad(lat2)) *
            math.sin(dLon / 2) * math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusKm * c;
  }

  static double _degToRad(double deg) => deg * (math.pi / 180.0);
}
