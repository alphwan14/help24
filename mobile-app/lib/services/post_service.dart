import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/post_model.dart';
import '../utils/feed_scope.dart';
import 'reputation_service.dart';
import 'storage_service.dart';

/// Filter options for fetching posts
class PostFilters {
  final String? searchQuery;
  final List<String>? categories;
  final String? city;
  final String? area;

  /// `posts.type` values to admit; null means every type.
  ///
  /// Was a single `String? type`, which could not express what the ranking
  /// engine expresses. Discover's "All" scope is `['request', 'offer']` — two
  /// types, not one and not all — so the old field forced the fallback to send
  /// `null` (no filter), which is how job posts appeared in Discover whenever
  /// ranking was unavailable. Supply these from [FeedScope.postTypes] rather
  /// than by hand.
  final List<String>? types;

  /// `posts.status` values to admit; null means every status.
  ///
  /// Browsing surfaces pass [kBrowsableStatuses]; Saved and My Posts pass null,
  /// because a shortlist and a management screen must keep showing listings
  /// through their whole lifecycle.
  final List<String>? statuses;

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
    this.types,
    this.statuses,
    this.urgency,
    this.minPrice,
    this.maxPrice,
    this.difficulty,
    this.limit = 50,
    this.offset = 0,
  });

  /// This filter set restricted to [scope], with the browsing status rule
  /// applied — the ONE place a client-side query is aligned with the engine.
  PostFilters forScope(FeedScope scope) => PostFilters(
        searchQuery: searchQuery,
        categories: categories,
        city: city,
        area: area,
        types: scope.postTypes,
        statuses: kBrowsableStatuses,
        urgency: urgency,
        minPrice: minPrice,
        maxPrice: maxPrice,
        difficulty: difficulty,
        limit: limit,
        offset: offset,
      );
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

  /// THE feed row shape. One definition, used by every read AND by the two
  /// writes that return a post.
  ///
  /// WHY THIS IS A CONSTANT
  /// ----------------------
  /// This string was previously copy-pasted at five read sites, and the two
  /// CREATE paths used a bare `.select()` instead — no author join. That is the
  /// whole reason a freshly posted card rendered `?` for a name, no avatar, no
  /// reputation and an "Offer Service" button on the poster's own post: the
  /// object handed back to the UI was the client's own draft with an id stapled
  /// to it, and a draft has no author. Making the shape a constant is what makes
  /// "a created post is indistinguishable from a fetched one" a property of the
  /// code rather than a thing someone has to remember.
  ///
  /// Byte-identical to `FEED_ROW_SELECT` in backend/src/feed/feed.repository.ts,
  /// so a ranked row, a fallback row and a just-created row all parse through
  /// the same `PostModel.fromJson` into the same object.
  static const String feedRowSelect =
      '*, users!author_user_id(name, email, profile_image, avatar_url, phone_number), '
      'post_images(image_url), '
      'applications(*, users!applicant_user_id(name, email, profile_image, avatar_url, profession))';

  /// Batch-warm the reputation cache for every distinct author in [authorIds]
  /// with ONE read of the public_provider_reputation view (migration 079, same
  /// shape as GET /reputation/:id), so cards paint their trust line together
  /// with the rest of the card instead of popping it in after a per-provider
  /// backend round-trip. Best-effort and bounded: on any error or timeout the
  /// feed renders exactly as before and ReputationCompact falls back to its
  /// existing per-provider backend fetch.
  static Future<void> _warmReputations(Iterable<String> authorIds) async {
    final ids = authorIds
        .where((id) => id.isNotEmpty && ReputationService.getCachedSync(id) == null)
        .toSet()
        .toList();
    if (ids.isEmpty) return;
    try {
      final rows = await _client
          .from('public_provider_reputation')
          .select()
          .inFilter('provider_id', ids)
          .timeout(const Duration(seconds: 2));
      ReputationService.seedAll([
        for (final row in rows as List)
          if (row is Map) Map<String, dynamic>.from(row),
      ]);
    } catch (e) {
      // View not applied / slow network — cards use the per-card fallback.
      debugPrint('[REPUTATION] feed warm-up skipped: $e');
    }
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
          .select(feedRowSelect)
          .filter('archived_at', 'is', null); // hide archived (soft-deleted) posts

      // Apply filters
      if (filters != null) {
        // Type filter — a LIST, so this path can express exactly what
        // fn_feed_candidates expresses (see FeedScope). A single type could
        // not describe Discover's "requests and offers, but not jobs".
        if (filters.types != null && filters.types!.isNotEmpty) {
          query = query.inFilter('type', filters.types!);
        }

        // Lifecycle filter. fn_feed_candidates has always restricted the ranked
        // feed to `status = 'open'`; this path never did, so the SAME tab showed
        // assigned, completed and disputed listings whenever ranking was down.
        if (filters.statuses != null && filters.statuses!.isNotEmpty) {
          query = query.inFilter('status', filters.statuses!);
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

        // Search query (title, description, or category — the category match is
        // what makes CUSTOM services like "TV Repair Technician" discoverable
        // by search; the client-side instant filter already matched category
        // names, so this only aligns the server result set with it)
        if (filters.searchQuery != null && filters.searchQuery!.isNotEmpty) {
          query = query.or(
            'title.ilike.%${filters.searchQuery}%,description.ilike.%${filters.searchQuery}%,category.ilike.%${filters.searchQuery}%',
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

      // Complete cards on first paint: warm author reputations BEFORE the feed
      // is handed to the UI (bounded to 2s; failure changes nothing).
      await _warmReputations(posts.map((p) => p.authorUserId));

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

  // NOTE: the previous _attachSettlement() read the RLS-locked `escrow` table
  // directly from the client to flag completed-but-unsettled posts ("Finalizing").
  // Removed for the S2 security lockdown (financial tables are backend-only now).
  // Phase C repopulates PostModel.payoutInProgress from the backend-derived
  // settlement state instead of a direct Supabase read.

  /// Fetch urgent request posts for top banner.
  /// Limited result set for fast UI; caller can do distance sorting.
  static Future<List<PostModel>> fetchUrgentPosts({int limit = 5}) async {
    try {
      final response = await _client
          .from('posts')
          .select(feedRowSelect)
          .filter('archived_at', 'is', null) // hide archived (soft-deleted) posts
          .eq('type', 'request')
          // Same browsing rule as Discover and Jobs. An urgent request that
          // already has a provider is not an emergency anyone can answer, and
          // listing it under "Urgent Help Needed" — and counting it in the
          // Discover badge — invited responses that would be refused.
          .inFilter('status', kBrowsableStatuses)
          .eq('is_urgent', true)
          .gt('urgent_expires_at', DateTime.now().toUtc().toIso8601String())
          .order('created_at', ascending: false)
          .limit(limit);
      final posts = (response as List)
          .map((json) => PostModel.fromJson(json))
          .toList();
      await _warmReputations(posts.map((p) => p.authorUserId));
      return posts;
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
          .select(feedRowSelect)
          .eq('type', 'job')
          .filter('archived_at', 'is', null); // hide archived (soft-deleted) posts

      // Apply filters (aligned with posts): location, category, price, difficulty, urgency, search)
      if (filters != null) {
        // Same lifecycle rule as Discover. The ranked jobs feed runs through
        // fn_feed_candidates, which admits only `status = 'open'`; without this
        // the Jobs tab gained filled and completed roles the moment ranking
        // became unavailable. The `type` is fixed to 'job' by the query above,
        // so filters.types is intentionally not consulted here.
        if (filters.statuses != null && filters.statuses!.isNotEmpty) {
          query = query.inFilter('status', filters.statuses!);
        }
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

      final jobs = (response as List)
          .map((json) => JobModel.fromJson(json))
          .toList();
      // Job cards render the same ReputationCompact trust line as post cards.
      await _warmReputations(jobs.map((j) => j.authorUserId));
      return jobs;
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

  /// Fetch specific posts by id (saved shortlist). Same select shape as the
  /// feed; archived posts are excluded so dead saves drop out naturally.
  static Future<List<PostModel>> fetchPostsByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    try {
      final response = await _client
          .from('posts')
          .select(feedRowSelect)
          .filter('archived_at', 'is', null)
          .inFilter('id', ids);
      final posts =
          (response as List).map((json) => PostModel.fromJson(json)).toList();
      await _warmReputations(posts.map((p) => p.authorUserId));
      return posts;
    } catch (e) {
      debugPrint('❌ Error fetching posts by ids: $e');
      if (_isNetworkError(e)) {
        throw PostServiceException(
          'Unable to connect. Please check your internet connection.',
          isNetworkError: true,
        );
      }
      throw PostServiceException('Failed to load saved posts.');
    }
  }

  /// Get a single post by ID with all related data
  static Future<PostModel?> getPostById(String id) async {
    try {
      final response = await _client
          .from('posts')
          .select(feedRowSelect)
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

      // Returns the row in FEED SHAPE — same select as every read, in the SAME
      // round-trip as the insert. There is no second fetch here: PostgREST
      // resolves the author join as part of `RETURNING`.
      final postResponse = await _client
          .from('posts')
          .insert(postData)
          .select(feedRowSelect)
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

      // Parsed with the SAME fromJson the feed uses, so the card that renders
      // next is fed a real post — author id, name, avatar, M-Pesa flag, server
      // timestamp and status all present — instead of the caller's draft.
      final created = PostModel.fromJson(postResponse);

      // Warm this author's reputation before the post reaches the UI, exactly as
      // the feed does, so the trust line paints with the rest of the card rather
      // than popping in a round-trip later. Bounded and best-effort.
      await _warmReputations([created.authorUserId]);

      return created.copyWith(
        // The relation was empty at RETURNING time — images are written to
        // post_images after the insert. These are the URLs we just uploaded.
        images: imageUrls,
        // Ownership must not be able to depend on a join succeeding. The insert
        // set author_user_id to exactly this value, so asserting it here gives
        // the owner check a second, independent guarantee.
        //
        // This also means PostCard's existing "show my own name instead of '?'"
        // fallback finally works: it was gated on isCurrentUser, which could
        // never be true while the author id was empty.
        authorUserId:
            created.authorUserId.isNotEmpty ? created.authorUserId : currentUserId,
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

      // Feed shape, same round-trip — see createPost.
      final response = await _client
          .from('posts')
          .insert(jobData)
          .select(feedRowSelect)
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

      final created = JobModel.fromJson(response);
      await _warmReputations([created.authorUserId]);

      return created.copyWith(
        images: imageUrls,
        authorUserId:
            created.authorUserId.isNotEmpty ? created.authorUserId : currentUserId,
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

  /// Check whether a user has any active offer posts.
  static Future<bool> hasOfferPosts(String userId) async {
    if (userId.isEmpty) return false;
    try {
      final result = await _client
          .from('posts')
          .select('id')
          .eq('author_user_id', userId)
          .eq('type', 'offer')
          .limit(1);
      return (result as List).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Every post the user has authored — ALL types, all lifecycle states,
  /// newest first. The single "my listings" query.
  ///
  /// It used to be two. This one excluded job posts (`.neq('type', 'job')`)
  /// while `UserProfileService.getAuthoredPosts` included them and re-declared
  /// the feed select by hand — so "my posts" meant different things depending on
  /// which screen asked, and one of them could never show a user their own job.
  ///
  /// The browsing filters ([kBrowsableStatuses], [FeedScope]) are deliberately
  /// NOT applied: managing your listings means seeing the assigned, completed
  /// and disputed ones too. That is the difference between a management surface
  /// and a browsing surface, and it is the reason this is a separate method
  /// rather than a scope.
  static Future<List<PostModel>> getMyPosts(
    String? currentUserId, {
    int limit = 100,
  }) async {
    if (currentUserId == null || currentUserId.isEmpty) return [];
    try {
      final response = await _client
          .from('posts')
          .select(feedRowSelect)
          .eq('author_user_id', currentUserId)
          .filter('archived_at', 'is', null)
          .order('created_at', ascending: false)
          .limit(limit);

      return (response as List)
          .map((json) => PostModel.fromJson(json))
          .toList();
    } catch (e) {
      throw PostServiceException('Failed to fetch my posts: $e');
    }
  }
}
