import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/post_model.dart';
import 'storage_service.dart';

/// Filter options for fetching posts
class PostFilters {
  final String? searchQuery;
  final List<String>? categories;
  final String? city;
  final String? area;
  final String? type; // 'request', 'offer', 'job', or null for all
  final String? urgency;
  final double? minPrice;
  final double? maxPrice;
  final String? difficulty;
  final int limit;
  final int offset;

  const PostFilters({
    this.searchQuery,
    this.categories,
    this.city,
    this.area,
    this.type,
    this.urgency,
    this.minPrice,
    this.maxPrice,
    this.difficulty,
    this.limit = 50,
    this.offset = 0,
  });
}

/// Exception for post service errors
class PostServiceException implements Exception {
  final String message;
  final bool isNetworkError;
  
  PostServiceException(this.message, {this.isNetworkError = false});
  
  @override
  String toString() => message;
}

/// Service for handling post-related operations with Supabase
class PostService {
  static get _client => Supabase.instance.client;
  
  /// Check if error is a network error
  static bool _isNetworkError(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    return errorStr.contains('socketexception') ||
           errorStr.contains('host lookup') ||
           errorStr.contains('network') ||
           errorStr.contains('connection') ||
           errorStr.contains('timeout') ||
           error is SocketException;
  }

  /// Fetch posts with optional filters
  /// Returns list of PostModel with images and applications
  static Future<List<PostModel>> fetchPosts({PostFilters? filters}) async {
    try {
      var query = _client
          .from('posts')
          .select('*, users!author_user_id(name, email, profile_image, avatar_url), post_images(image_url), applications(*, users!applicant_user_id(name, email, profile_image, avatar_url))');

      // Apply filters
      if (filters != null) {
        // Type filter (request/offer/job)
        if (filters.type != null && filters.type!.isNotEmpty) {
          query = query.eq('type', filters.type!);
        }

        // Category filter
        if (filters.categories != null && filters.categories!.isNotEmpty) {
          query = query.inFilter('category', filters.categories!);
        }

        // Location filter (city)
        if (filters.city != null && filters.city!.isNotEmpty) {
          query = query.ilike('location', '%${filters.city}%');
        }

        // Location filter (area)
        if (filters.area != null && filters.area!.isNotEmpty) {
          query = query.ilike('location', '%${filters.area}%');
        }

        // Urgency filter
        if (filters.urgency != null && filters.urgency!.isNotEmpty) {
          query = query.eq('urgency', filters.urgency!);
        }

        // Difficulty filter
        if (filters.difficulty != null && filters.difficulty!.isNotEmpty) {
          query = query.eq('difficulty', filters.difficulty!);
        }

        // Price range filter
        if (filters.minPrice != null) {
          query = query.gte('price', filters.minPrice!);
        }
        if (filters.maxPrice != null) {
          query = query.lte('price', filters.maxPrice!);
        }

        // Search query (title or description)
        if (filters.searchQuery != null && filters.searchQuery!.isNotEmpty) {
          query = query.or(
            'title.ilike.%${filters.searchQuery}%,description.ilike.%${filters.searchQuery}%',
          );
        }
      }

      // Order by created_at descending and apply pagination
      final response = await query
          .order('created_at', ascending: false)
          .range(
            filters?.offset ?? 0,
            (filters?.offset ?? 0) + (filters?.limit ?? 50) - 1,
          );

      // Debug: Log the raw response to see image data
      final posts = (response as List).map((json) {
        debugPrint('📦 Post: ${json['title']} | Images: ${json['post_images']}');
        return PostModel.fromJson(json);
      }).toList();
      
      debugPrint('✅ Loaded ${posts.length} posts');
      for (final post in posts.take(3)) {
        debugPrint('  - ${post.title}: ${post.images.length} images');
      }
      
      return posts;
    } catch (e) {
      debugPrint('❌ Error fetching posts: $e');
      if (_isNetworkError(e)) {
        throw PostServiceException(
          'Unable to connect. Please check your internet connection.',
          isNetworkError: true,
        );
      }
      throw PostServiceException('Failed to load posts. Please try again.');
    }
  }

  /// Fetch urgent request posts for top banner.
  /// Limited result set for fast UI; caller can do distance sorting.
  static Future<List<PostModel>> fetchUrgentPosts({int limit = 5}) async {
    try {
      final response = await _client
          .from('posts')
          .select('*, users!author_user_id(name, email, profile_image, avatar_url), post_images(image_url), applications(*, users!applicant_user_id(name, email, profile_image, avatar_url))')
          .eq('type', 'request')
          .eq('is_urgent', true)
          .gt('urgent_expires_at', DateTime.now().toIso8601String())
          .order('created_at', ascending: false)
          .limit(limit);
      return (response as List)
          .map((json) => PostModel.fromJson(json))
          .toList();
    } catch (e) {
      debugPrint('❌ Error fetching urgent posts: $e');
      if (_isNetworkError(e)) {
        throw PostServiceException(
          'Unable to connect. Please check your internet connection.',
          isNetworkError: true,
        );
      }
      throw PostServiceException('Failed to load urgent posts.');
    }
  }

  /// Fetch only job-type posts
  static Future<List<JobModel>> fetchJobs({PostFilters? filters}) async {
    try {
      var query = _client
          .from('posts')
          .select('*, users!author_user_id(name, email, profile_image, avatar_url), post_images(image_url), applications(*, users!applicant_user_id(name, email, profile_image, avatar_url))')
          .eq('type', 'job');

      // Apply filters (aligned with posts): location, category, price, difficulty, urgency, search)
      if (filters != null) {
        if (filters.city != null && filters.city!.isNotEmpty) {
          query = query.ilike('location', '%${filters.city}%');
        }
        if (filters.area != null && filters.area!.isNotEmpty) {
          query = query.ilike('location', '%${filters.area}%');
        }
        if (filters.categories != null && filters.categories!.isNotEmpty) {
          query = query.inFilter('category', filters.categories!);
        }
        if (filters.urgency != null && filters.urgency!.isNotEmpty) {
          query = query.eq('urgency', filters.urgency!);
        }
        if (filters.difficulty != null && filters.difficulty!.isNotEmpty) {
          query = query.eq('difficulty', filters.difficulty!);
        }
        if (filters.minPrice != null) {
          query = query.gte('price', filters.minPrice!);
        }
        if (filters.maxPrice != null) {
          query = query.lte('price', filters.maxPrice!);
        }
        if (filters.searchQuery != null && filters.searchQuery!.isNotEmpty) {
          query = query.or(
            'title.ilike.%${filters.searchQuery}%,description.ilike.%${filters.searchQuery}%',
          );
        }
      }

      final response = await query
          .order('created_at', ascending: false)
          .range(
            filters?.offset ?? 0,
            (filters?.offset ?? 0) + (filters?.limit ?? 50) - 1,
          );

      return (response as List)
          .map((json) => JobModel.fromJson(json))
          .toList();
    } catch (e) {
      debugPrint('❌ Error fetching jobs: $e');
      if (_isNetworkError(e)) {
        throw PostServiceException(
          'Unable to connect. Please check your internet connection.',
          isNetworkError: true,
        );
      }
      throw PostServiceException('Failed to load jobs. Please try again.');
    }
  }

  /// Get a single post by ID with all related data
  static Future<PostModel?> getPostById(String id) async {
    try {
      final response = await _client
          .from('posts')
          .select('*, users!author_user_id(name, email, profile_image, avatar_url), post_images(image_url), applications(*, users!applicant_user_id(name, email, profile_image, avatar_url))')
          .eq('id', id)
          .maybeSingle();

      if (response == null) return null;
      return PostModel.fromJson(response);
    } catch (e) {
      throw PostServiceException('Failed to get post: $e');
    }
  }

  /// Create a new post with optional images. Requires [currentUserId] (Supabase/Firebase user id).
  static Future<PostModel> createPost(
    PostModel post, {
    required String? currentUserId,
    List<XFile>? imageFiles,
    void Function(int completed, int total)? onImageUploadProgress,
  }) async {
    if (currentUserId == null || currentUserId.isEmpty) {
      throw PostServiceException('Sign in to create a post.');
    }
    try {
      final postData = post.toJson();
      postData['author_user_id'] = currentUserId;
      postData['author_temp_id'] = '';
      if (postData['is_urgent'] == true && postData['urgent_expires_at'] == null) {
        postData['urgent_expires_at'] = DateTime.now().add(const Duration(hours: 1)).toIso8601String();
      }

      final postResponse = await _client
          .from('posts')
          .insert(postData)
          .select()
          .single();

      final postId = postResponse['id'] as String;
      debugPrint('✅ Post created: id=$postId author_user_id=$currentUserId');

      // Upload images if provided (optional - post succeeds even without images)
      List<String> imageUrls = [];
      if (imageFiles != null && imageFiles.isNotEmpty) {
        debugPrint('');
        debugPrint('═══════════════════════════════════════════');
        debugPrint('📤 STARTING IMAGE UPLOAD FOR POST: $postId');
        debugPrint('═══════════════════════════════════════════');
        debugPrint('📤 Number of images to upload: ${imageFiles.length}');
        
        try {
          imageUrls = await StorageService.uploadMultipleImages(
            imageFiles,
            onProgress: (completed, total) {
              debugPrint('📤 Upload progress: $completed / $total');
              onImageUploadProgress?.call(completed, total);
            },
          );
          debugPrint('📤 Successfully uploaded ${imageUrls.length} images');
          
          if (imageUrls.isEmpty) {
            debugPrint('⚠️ WARNING: No images were uploaded successfully');
          }

          // Insert image URLs into post_images table
          for (int i = 0; i < imageUrls.length; i++) {
            final url = imageUrls[i];
            debugPrint('💾 Saving image ${i + 1}/${imageUrls.length} to post_images...');
            debugPrint('   URL: $url');
            
            try {
              await _client.from('post_images').insert({
                'post_id': postId,
                'image_url': url,
              });
              debugPrint('✅ Image ${i + 1} saved to post_images table');
            } catch (dbError) {
              debugPrint('❌ FAILED to save image ${i + 1} to DB: $dbError');
              // Continue with other images even if one fails
            }
          }
        } catch (e) {
          // Log error prominently but don't fail the post creation
          debugPrint('');
          debugPrint('╔═══════════════════════════════════════════╗');
          debugPrint('║ ❌ IMAGE UPLOAD FAILED                      ║');
          debugPrint('║ Error: $e');
          debugPrint('║ Post was created without images           ║');
          debugPrint('╚═══════════════════════════════════════════╝');
          debugPrint('');
        }
        
        debugPrint('═══════════════════════════════════════════');
        debugPrint('📤 IMAGE UPLOAD COMPLETE');
        debugPrint('   Total images uploaded: ${imageUrls.length}');
        debugPrint('═══════════════════════════════════════════');
        debugPrint('');
      } else {
        debugPrint('📤 No images to upload for this post');
      }

      return post.copyWith(
        id: postId,
        authorTempId: '',
        images: imageUrls,
      );
    } catch (e) {
      throw PostServiceException('Failed to create post: $e');
    }
  }

  /// Create a job post. Requires [currentUserId].
  static Future<JobModel> createJob(
    JobModel job, {
    required String? currentUserId,
    List<XFile>? imageFiles,
    void Function(int completed, int total)? onImageUploadProgress,
  }) async {
    if (currentUserId == null || currentUserId.isEmpty) {
      throw PostServiceException('Sign in to create a job.');
    }
    try {
      final jobData = job.toJson();
      jobData['author_user_id'] = currentUserId;
      jobData['author_temp_id'] = '';

      final response = await _client
          .from('posts')
          .insert(jobData)
          .select()
          .single();

      final jobId = response['id'] as String;
      debugPrint('✅ Job created: id=$jobId author_user_id=$currentUserId');

      List<String> imageUrls = [];
      if (imageFiles != null && imageFiles.isNotEmpty) {
        imageUrls = await StorageService.uploadMultipleImages(
          imageFiles,
          onProgress: onImageUploadProgress,
        );

        for (final url in imageUrls) {
          await _client.from('post_images').insert({
            'post_id': jobId,
            'image_url': url,
          });
        }
      }

      return job.copyWith(
        id: jobId,
        authorTempId: '',
        images: imageUrls,
      );
    } catch (e) {
      throw PostServiceException('Failed to create job: $e');
    }
  }

  /// Update an existing post
  static Future<void> updatePost(String postId, Map<String, dynamic> updates) async {
    try {
      await _client
          .from('posts')
          .update(updates)
          .eq('id', postId);
    } catch (e) {
      throw PostServiceException('Failed to update post: $e');
    }
  }

  /// Delete a post and its associated images
  static Future<void> deletePost(String postId) async {
    try {
      // Get image URLs first
      final images = await _client
          .from('post_images')
          .select('image_url')
          .eq('post_id', postId);

      // Delete from storage
      if ((images as List).isNotEmpty) {
        final urls = images
            .map((img) => img['image_url'] as String)
            .toList();
        await StorageService.deleteMultipleImages(urls);
      }

      // Delete post (cascades to post_images and applications)
      await _client.from('posts').delete().eq('id', postId);
    } catch (e) {
      throw PostServiceException('Failed to delete post: $e');
    }
  }

  /// Get posts by the current user. Returns empty list if [currentUserId] is null.
  static Future<List<PostModel>> getMyPosts(String? currentUserId) async {
    if (currentUserId == null || currentUserId.isEmpty) return [];
    try {
      final response = await _client
          .from('posts')
          .select('*, users!author_user_id(name, email, profile_image, avatar_url), post_images(image_url), applications(*, users!applicant_user_id(name, email, profile_image, avatar_url))')
          .eq('author_user_id', currentUserId)
          .neq('type', 'job')
          .order('created_at', ascending: false);

      return (response as List)
          .map((json) => PostModel.fromJson(json))
          .toList();
    } catch (e) {
      throw PostServiceException('Failed to fetch my posts: $e');
    }
  }
}
