import 'dart:async';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/post_model.dart';
import '../services/post_service.dart';
import '../services/chat_service_supabase.dart';
import '../services/application_service.dart';
import '../services/auth_service.dart';
import '../services/cache_service.dart';
import '../services/jobs_service.dart';
import '../services/startup_prefetch.dart';
import '../services/supabase_auth_bridge.dart';
import '../utils/error_mapper.dart';

class AppProvider extends ChangeNotifier {
  bool _isDarkMode = true;
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
  String? _priorityLocationCity;

  /// Post ids the current user has applied to / sent an offer on. Server-derived
  /// (from the applications table) so the "Applied / Offer sent" state is TRUE
  /// across refreshes, tab switches and app restarts — not a per-session flag
  /// that reverts on the next feed load and re-invites a duplicate.
  Set<String> _appliedPostIds = {};

  // Getters
  bool get isDarkMode => _isDarkMode;
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
  String? get priorityLocationCity => _priorityLocationCity;

  AppProvider({bool initialDarkMode = true}) : _isDarkMode = initialDarkMode {
    _loadInitialData();
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
          if (_posts.isNotEmpty) {
            await CacheService.savePosts(_posts);
          }
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

      _posts = await PostService.fetchPosts(filters: filters);
      if (_posts.isNotEmpty) {
        await CacheService.savePosts(_posts);
      }
    } catch (e) {
      _error = ErrorMapper.toMessage(e, context: ErrorContext.loadFeed);
      debugPrint('[AppProvider] loadPosts failed: $e');
    } finally {
      // Runs on every exit path (prefetch, offline cache, network): author
      // avatars start caching with the feed so cards render them instantly.
      _warmAvatarUrls(_posts.map((p) => p.authorAvatar));
      _isLoadingPosts = false;
      notifyListeners();
    }
  }

  /// Load jobs from Supabase.
  /// When offline: keeps cached _jobs, does not clear or show endless loading.
  Future<void> loadJobs() async {
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
      _jobs = await PostService.fetchJobs(filters: filters);
      if (_jobs.isNotEmpty) {
        await CacheService.saveJobs(_jobs);
      }
    } catch (e) {
      _error = ErrorMapper.toMessage(e, context: ErrorContext.loadFeed);
      debugPrint('[AppProvider] loadJobs failed: $e');
    } finally {
      _warmAvatarUrls(_jobs.map((j) => j.authorAvatarUrl));
      _isLoadingJobs = false;
      notifyListeners();
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

  /// Submit application to a post. Requires [currentUserId].
  Future<bool> submitApplicationToPost(
    String postId, {
    required String? currentUserId,
    required String message,
    required double proposedPrice,
  }) async {
    try {
      await AuthService.ensureCurrentUserInSupabase();
      final application = await ApplicationService.submitApplication(
        postId: postId,
        currentUserId: currentUserId ?? '',
        message: message,
        proposedPrice: proposedPrice,
      );

      // Server-derived applied state: mark this post so its card flips to the
      // done state and survives the next feed reload.
      _appliedPostIds.add(postId);

      // Update local post with new application
      final index = _posts.indexWhere((p) => p.id == postId);
      if (index != -1) {
        final post = _posts[index];
        final updatedApplications = [...post.applications, application];
        _posts[index] = post.copyWith(applications: updatedApplications);
      }
      notifyListeners();

      return true;
    } catch (e) {
      _error = ErrorMapper.toMessage(e, context: ErrorContext.apply);
      debugPrint('[AppProvider] submitApplicationToPost failed: $e');
      return false;
    }
  }

  /// Submit application to a job. Requires [currentUserId].
  Future<bool> submitApplicationToJob(
    String jobId, {
    required String? currentUserId,
    required String message,
    required double proposedPrice,
  }) async {
    try {
      await AuthService.ensureCurrentUserInSupabase();
      final application = await ApplicationService.submitApplication(
        postId: jobId,
        currentUserId: currentUserId ?? '',
        message: message,
        proposedPrice: proposedPrice,
      );

      // Server-derived applied state so "Applied" survives the next loadJobs().
      _appliedPostIds.add(jobId);

      // Update local job with new application
      final index = _jobs.indexWhere((j) => j.id == jobId);
      if (index != -1) {
        final job = _jobs[index];
        final updatedApplications = [...job.applications, application];
        _jobs[index] = job.copyWith(
          applications: updatedApplications,
          hasApplied: true,
        );
      }
      notifyListeners();

      return true;
    } catch (e) {
      _error = ErrorMapper.toMessage(e, context: ErrorContext.apply);
      debugPrint('[AppProvider] submitApplicationToJob failed: $e');
      return false;
    }
  }

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
      _conversations = [];
      _hasMoreConversations = true;
      _conversationsUserId = '';
      _conversationStreamSubscription?.cancel();
      _conversationStreamSubscription = null;
      notifyListeners();
      return;
    }
    if (_conversationsUserId == currentUserId &&
        _conversationStreamSubscription != null) {
      return; // Already syncing for this user — nothing to do.
    }
    _conversationsUserId = currentUserId;
    _error = null;
    _hasMoreConversations = true;
    _conversationStreamSubscription?.cancel();
    _conversationStreamSubscription = null;

    // Disk hydration first: whatever we knew last session shows instantly.
    if (_conversations.isEmpty) {
      final cached = await CacheService.loadConversations();
      if (_conversations.isEmpty && cached.isNotEmpty) {
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
        if (_conversations.length > list.length) {
          _conversations = list + _conversations.sublist(list.length);
        } else {
          _conversations = list;
        }
        _isLoadingConversations = false;
        if (list.isNotEmpty) {
          CacheService.saveConversations(list);
          _warmAvatarCache(list);
        }
        notifyListeners();
      },
      onError: (e) {
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
    _loadingMoreConversations = true;
    notifyListeners();
    try {
      final result = await ChatServiceSupabase.getConversationsPage(
        currentUserId,
        offset: _conversations.length,
      );
      if (result.list.isEmpty) {
        _hasMoreConversations = false;
      } else {
        final existingIds = _conversations.map((c) => c.id).toSet();
        final newList = result.list.where((c) => !existingIds.contains(c.id)).toList();
        _conversations = _conversations + newList;
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

  void toggleTheme() {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
    // Persist immediately; fire-and-forget (non-blocking).
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool('isDarkMode', _isDarkMode),
    );
  }

  // ==================== FILTERS ====================

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
    // Reload posts with new search query
    loadPosts();
  }

  void setSelectedFilter(String filter) {
    _selectedFilter = filter;
    notifyListeners();
    loadPosts();
  }

  void toggleCategory(String category) {
    if (_selectedCategories.contains(category)) {
      _selectedCategories.remove(category);
    } else {
      _selectedCategories.add(category);
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
    loadPosts();
  }

  /// Prioritize posts near the user's detected city without filtering out others.
  void setPriorityLocationCity(String? city) {
    final next = city?.trim();
    if (_priorityLocationCity == next) return;
    _priorityLocationCity = (next == null || next.isEmpty) ? null : next;
    notifyListeners();
  }

  /// Apply current filters and reload posts
  Future<void> applyFilters() async {
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

      // Price filter
      if (post.price < _priceRange.start || post.price > _priceRange.end) {
        return false;
      }

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
