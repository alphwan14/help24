import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/post_model.dart';
import '../services/post_service.dart';
import '../services/message_service.dart';
import '../services/application_service.dart';

class AppProvider extends ChangeNotifier {
  bool _isDarkMode = true;
  List<PostModel> _posts = [];
  List<JobModel> _jobs = [];
  List<Conversation> _conversations = [];
  
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

  /// Load initial data from Supabase
  Future<void> _loadInitialData() async {
    await Future.wait([
      loadPosts(),
      loadJobs(),
      loadConversations(),
    ]);
  }

  /// Refresh all data
  Future<void> refreshAll() async {
    await _loadInitialData();
  }

  // ==================== POSTS ====================

  /// Load posts from Supabase with current filters
  Future<void> loadPosts() async {
    _isLoadingPosts = true;
    _error = null;
    notifyListeners();

    try {
      // Build filters
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
    } catch (e) {
      _error = 'Failed to load posts: $e';
      print(_error);
    } finally {
      _isLoadingPosts = false;
      notifyListeners();
    }
  }

  /// Load jobs from Supabase
  Future<void> loadJobs() async {
    _isLoadingJobs = true;
    _error = null;
    notifyListeners();

    try {
      _jobs = await PostService.fetchJobs();
    } catch (e) {
      _error = 'Failed to load jobs: $e';
      print(_error);
    } finally {
      _isLoadingJobs = false;
      notifyListeners();
    }
  }

  /// Create a new post with optional images
  Future<PostModel?> createPost(
    PostModel post, {
    List<XFile>? imageFiles,
    void Function(int completed, int total)? onImageUploadProgress,
  }) async {
    _isPosting = true;
    _error = null;
    notifyListeners();

    try {
      final createdPost = await PostService.createPost(
        post,
        imageFiles: imageFiles,
        onImageUploadProgress: onImageUploadProgress,
      );

      // Add to local list
      _posts.insert(0, createdPost);
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

  /// Create a new job with optional images
  Future<JobModel?> createJob(
    JobModel job, {
    List<XFile>? imageFiles,
    void Function(int completed, int total)? onImageUploadProgress,
  }) async {
    _isPosting = true;
    _error = null;
    notifyListeners();

    try {
      final createdJob = await PostService.createJob(
        job,
        imageFiles: imageFiles,
        onImageUploadProgress: onImageUploadProgress,
      );

      _jobs.insert(0, createdJob);
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

  // ==================== APPLICATIONS ====================

  /// Submit application to a post
  Future<bool> submitApplicationToPost(
    String postId, {
    required String message,
    required double proposedPrice,
  }) async {
    try {
      final application = await ApplicationService.submitApplication(
        postId: postId,
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

  /// Submit application to a job
  Future<bool> submitApplicationToJob(
    String jobId, {
    required String message,
    required double proposedPrice,
  }) async {
    try {
      final application = await ApplicationService.submitApplication(
        postId: jobId,
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

  /// Load conversations from Supabase
  Future<void> loadConversations() async {
    _isLoadingConversations = true;
    _error = null;
    notifyListeners();

    try {
      _conversations = await MessageService.getConversations();
    } catch (e) {
      _error = 'Failed to load conversations: $e';
      print(_error);
    } finally {
      _isLoadingConversations = false;
      notifyListeners();
    }
  }

  /// Get or create conversation with a user
  Future<Conversation?> getOrCreateConversation({
    required String otherUserId,
    required String otherUserName,
    String? initialMessage,
  }) async {
    try {
      final conversation = await MessageService.getOrCreateConversation(
        postAuthorId: otherUserId,
        postAuthorName: otherUserName,
        initialMessage: initialMessage,
      );

      // Update local conversations list
      final index = _conversations.indexWhere((c) => c.id == conversation.id);
      if (index == -1) {
        _conversations.insert(0, conversation);
      } else {
        _conversations[index] = conversation;
      }
      notifyListeners();

      return conversation;
    } catch (e) {
      _error = 'Failed to get conversation: $e';
      print(_error);
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
