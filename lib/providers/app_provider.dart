import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/post_model.dart';
import '../services/post_service.dart';
import '../services/chat_service_supabase.dart';
import '../services/application_service.dart';
import '../services/auth_service.dart';
import '../services/cache_service.dart';
import '../services/user_profile_service.dart';
import '../services/supabase_auth_bridge.dart';

class AppProvider extends ChangeNotifier {
  bool _isDarkMode = true;
  List<PostModel> _posts = [];
  List<JobModel> _jobs = [];
  List<Conversation> _conversations = [];
  StreamSubscription<List<Conversation>>? _conversationStreamSubscription;
  
  // Loading states
  bool _isLoadingPosts = false;
  bool _isLoadingJobs = false;
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
  double? _minRating;

  // Getters
  bool get isDarkMode => _isDarkMode;
  List<PostModel> get posts => _posts;
  List<JobModel> get jobs => _jobs;
  List<Conversation> get conversations => _conversations;
  bool get isLoadingPosts => _isLoadingPosts;
  bool get isLoadingJobs => _isLoadingJobs;
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
  double? get minRating => _minRating;

  AppProvider() {
    // Load data from Supabase on initialization
    _loadInitialData();
  }

  /// Load initial data from Supabase (conversations loaded when Messages screen opens with user id)
  Future<void> _loadInitialData() async {
    await Future.wait([
      loadPosts(),
      loadJobs(),
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
      _error = 'Failed to load posts: $e';
      print(_error);
    } finally {
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
      _error = 'Failed to load jobs: $e';
      print(_error);
    } finally {
      _isLoadingJobs = false;
      notifyListeners();
    }
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
      notifyListeners();
      return createdPost;
    } catch (e) {
      _error = 'Failed to create post: $e';
      print(_error);
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
      _error = 'Failed to create job: $e';
      print(_error);
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
      await PostService.deletePost(postId);
      _posts.removeWhere((p) => p.id == postId);
      _jobs.removeWhere((j) => j.id == postId);
      if (_posts.isNotEmpty) CacheService.savePosts(_posts);
      if (_jobs.isNotEmpty) CacheService.saveJobs(_jobs);
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to delete post: $e';
      debugPrint(_error);
      return false;
    }
  }

  /// Mark a job/post as completed (owner only). Updates backend, increments user completed_jobs_count, removes from list.
  Future<bool> markJobCompleted(String postId, String? currentUserId) async {
    if (currentUserId == null || currentUserId.isEmpty) return false;
    final idx = _jobs.indexWhere((j) => j.id == postId);
    if (idx == -1) return false;
    if (_jobs[idx].authorUserId != currentUserId) return false;
    try {
      await PostService.updatePost(postId, {'status': 'completed'});
      await UserProfileService.incrementCompletedJobsCount(currentUserId);
      _jobs.removeWhere((j) => j.id == postId);
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to mark as completed: $e';
      debugPrint(_error);
      return false;
    }
  }

  // ==================== APPLICATIONS ====================

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

      // Update local post with new application
      final index = _posts.indexWhere((p) => p.id == postId);
      if (index != -1) {
        final post = _posts[index];
        final updatedApplications = [...post.applications, application];
        _posts[index] = post.copyWith(applications: updatedApplications);
        notifyListeners();
      }

      return true;
    } catch (e) {
      _error = 'Failed to submit application: $e';
      print(_error);
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

      // Update local job with new application
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

      return true;
    } catch (e) {
      _error = 'Failed to submit application: $e';
      print(_error);
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

  /// Real-time chat list from Supabase. When offline, show cached conversations if any.
  Future<void> loadConversations(String currentUserId) async {
    if (currentUserId.isEmpty) {
      _conversations = [];
      _hasMoreConversations = true;
      _conversationStreamSubscription?.cancel();
      _conversationStreamSubscription = null;
      notifyListeners();
      return;
    }
    _error = null;
    _hasMoreConversations = true;
    _conversationStreamSubscription?.cancel();
    _isLoadingConversations = true;
    notifyListeners();

    final results = await Connectivity().checkConnectivity();
    final offline = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (offline) {
      final cached = await CacheService.loadConversations();
      if (cached.isNotEmpty) {
        _conversations = cached;
      }
      _isLoadingConversations = false;
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
        }
        notifyListeners();
      },
      onError: (e) {
        _error = 'Failed to load conversations: $e';
        _isLoadingConversations = false;
        notifyListeners();
      },
    );
  }

  void stopListeningToConversations() {
    _conversationStreamSubscription?.cancel();
    _conversationStreamSubscription = null;
  }

  bool _hasMoreConversations = true;
  bool _loadingMoreConversations = false;

  bool get hasMoreConversations => _hasMoreConversations;
  bool get loadingMoreConversations => _loadingMoreConversations;

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
      _error = 'Failed to create conversation: $e';
      debugPrint(_error);
      return null;
    }
  }

  /// Create a chat when a request/application is accepted (Firestore only).
  Future<Conversation?> createConversationOnAccept({
    required String currentUserId,
    required String otherUserId,
    required String otherUserName,
  }) async {
    try {
      await SupabaseAuthBridge.ensureSessionForWriteAsync();
      final conversation = await ChatServiceSupabase.createChat(
        user1Id: currentUserId,
        user2Id: otherUserId,
        currentUserId: currentUserId,
      );
      final index = _conversations.indexWhere((c) => c.id == conversation.id);
      if (index == -1) {
        _conversations.insert(0, conversation);
      } else {
        _conversations[index] = conversation;
      }
      notifyListeners();
      return conversation;
    } catch (e) {
      _error = 'Failed to create conversation: $e';
      debugPrint(_error);
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

  void setMinRating(double? rating) {
    _minRating = rating;
    notifyListeners();
  }

  void clearFilters() {
    _selectedCategories = {};
    _selectedCity = '';
    _selectedArea = '';
    _priceRange = const RangeValues(0, 100000);
    _selectedDifficulty = null;
    _selectedUrgency = null;
    _minRating = null;
    notifyListeners();
    loadPosts();
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
        _minRating != null ||
        _priceRange.start > 0 ||
        _priceRange.end < 100000;
  }

  /// Get filtered posts (local filtering for instant UI)
  List<PostModel> get filteredPosts {
    return _posts.where((post) {
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

      // Rating filter
      if (_minRating != null && post.rating < _minRating!) {
        return false;
      }

      return true;
    }).toList();
  }

  /// Clear error message
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
