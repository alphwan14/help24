import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import '../config/supabase_config.dart';
import '../models/post_model.dart';
import '../utils/guest_id.dart';
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
  /// Get Supabase client safely
  static get _client {
    if (!SupabaseConfig.isInitialized) {
      throw PostServiceException('Supabase not initialized', isNetworkError: true);
    }
    return SupabaseConfig.client;
  }
  
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
          .select('*, post_images(image_url), applications(*)');

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

  /// Fetch only job-type posts
  static Future<List<JobModel>> fetchJobs({PostFilters? filters}) async {
    try {
      var query = _client
          .from('posts')
          .select('*, post_images(image_url), applications(*)')
          .eq('type', 'job');

      // Apply additional filters
      if (filters != null) {
        if (filters.city != null && filters.city!.isNotEmpty) {
          query = query.ilike('location', '%${filters.city}%');
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
          .select('*, post_images(image_url), applications(*)')
          .eq('id', id)
          .maybeSingle();

      if (response == null) return null;
      return PostModel.fromJson(response);
    } catch (e) {
      throw PostServiceException('Failed to get post: $e');
    }
  }

  /// Create a new post with optional images
  /// Returns the created post with its ID
  static Future<PostModel> createPost(
    PostModel post, {
    List<XFile>? imageFiles,
    void Function(int completed, int total)? onImageUploadProgress,
  }) async {
    try {
      // Get guest ID
      final guestId = GuestId.currentId;
      final guestName = GuestId.currentName;

      // Prepare post data
      final postData = post.toJson();
      postData['author_temp_id'] = guestId;
      postData['author_name'] = guestName;

      // Insert post first (so we have an ID even if image upload fails)
      final postResponse = await _client
          .from('posts')
          .insert(postData)
          .select()
          .single();

      final postId = postResponse['id'] as String;

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

      // Return the created post with images
      return post.copyWith(
        id: postId,
        authorTempId: guestId,
        authorName: guestName,
        images: imageUrls,
      );
    } catch (e) {
      throw PostServiceException('Failed to create post: $e');
    }
  }

  /// Create a job post
  static Future<JobModel> createJob(
    JobModel job, {
    List<XFile>? imageFiles,
    void Function(int completed, int total)? onImageUploadProgress,
  }) async {
    try {
      final guestId = GuestId.currentId;

      final jobData = job.toJson();
      jobData['author_temp_id'] = guestId;

      final response = await _client
          .from('posts')
          .insert(jobData)
          .select()
          .single();

      final jobId = response['id'] as String;

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
        authorTempId: guestId,
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

  /// Get posts by the current guest user
  static Future<List<PostModel>> getMyPosts() async {
    try {
      final guestId = GuestId.currentId;
      
      final response = await _client
          .from('posts')
          .select('*, post_images(image_url), applications(*)')
          .eq('author_temp_id', guestId)
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
