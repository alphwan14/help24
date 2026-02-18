import 'package:flutter/foundation.dart';
import '../config/supabase_config.dart';
import '../models/post_model.dart';

/// Service for handling job/post applications with Supabase. Uses real user ids.
class ApplicationService {
  static final _client = SupabaseConfig.client;

  static const _applicationsSelect = '*, users(name, email, profile_image, avatar_url)';

  /// Submit an application. Requires [currentUserId]. Name/avatar come from users join on read.
  static Future<Application> submitApplication({
    required String postId,
    required String currentUserId,
    required String message,
    required double proposedPrice,
  }) async {
    if (currentUserId.isEmpty) {
      throw ApplicationServiceException('Sign in to submit an application.');
    }
    try {
      final applicationData = {
        'post_id': postId,
        'applicant_user_id': currentUserId,
        'applicant_temp_id': '',
        'applicant_name': '',
        'message': message,
        'proposed_price': proposedPrice,
      };

      final response = await _client
          .from('applications')
          .insert(applicationData)
          .select(_applicationsSelect)
          .single();

      final app = Application.fromJson(response);
      debugPrint('✅ Application submitted: post=$postId applicant_user_id=$currentUserId');
      return app;
    } catch (e) {
      debugPrint('❌ Application submit failed: $e');
      throw ApplicationServiceException('Failed to submit application: $e');
    }
  }

  /// Get all applications for a post (with applicant name/avatar from users join).
  static Future<List<Application>> getApplicationsForPost(String postId) async {
    try {
      final response = await _client
          .from('applications')
          .select(_applicationsSelect)
          .eq('post_id', postId)
          .order('created_at', ascending: false);

      return (response as List)
          .map((json) => Application.fromJson(json))
          .toList();
    } catch (e) {
      throw ApplicationServiceException('Failed to fetch applications: $e');
    }
  }

  /// Get applications submitted by the current user. Returns [] if [currentUserId] is null.
  static Future<List<Application>> getMyApplications(String? currentUserId) async {
    if (currentUserId == null || currentUserId.isEmpty) return [];
    try {
      final response = await _client
          .from('applications')
          .select(_applicationsSelect)
          .eq('applicant_user_id', currentUserId)
          .order('created_at', ascending: false);

      return (response as List)
          .map((json) => Application.fromJson(json))
          .toList();
    } catch (e) {
      throw ApplicationServiceException('Failed to fetch my applications: $e');
    }
  }

  /// Check if current user has already applied to a post.
  static Future<bool> hasApplied(String postId, String? currentUserId) async {
    if (currentUserId == null || currentUserId.isEmpty) return false;
    try {
      final response = await _client
          .from('applications')
          .select('id')
          .eq('post_id', postId)
          .eq('applicant_user_id', currentUserId)
          .maybeSingle();

      return response != null;
    } catch (e) {
      return false;
    }
  }

  /// Delete an application (only if it belongs to current user).
  static Future<void> deleteApplication(String applicationId, String? currentUserId) async {
    if (currentUserId == null || currentUserId.isEmpty) {
      throw ApplicationServiceException('Sign in to delete an application.');
    }
    try {
      await _client
          .from('applications')
          .delete()
          .eq('id', applicationId)
          .eq('applicant_user_id', currentUserId);
    } catch (e) {
      throw ApplicationServiceException('Failed to delete application: $e');
    }
  }

  /// Get count of applications for a post
  static Future<int> getApplicationCount(String postId) async {
    try {
      final response = await _client
          .from('applications')
          .select('id')
          .eq('post_id', postId);

      return (response as List).length;
    } catch (e) {
      return 0;
    }
  }

  /// Get applications for posts owned by current user (with applicant name/avatar).
  static Future<List<Application>> getApplicationsToMyPosts(String? currentUserId) async {
    if (currentUserId == null || currentUserId.isEmpty) return [];
    try {
      final postsResponse = await _client
          .from('posts')
          .select('id')
          .eq('author_user_id', currentUserId);

      if ((postsResponse as List).isEmpty) return [];

      final postIds = postsResponse.map((p) => p['id'] as String).toList();

      final response = await _client
          .from('applications')
          .select(_applicationsSelect)
          .inFilter('post_id', postIds)
          .order('created_at', ascending: false);

      return (response as List)
          .map((json) => Application.fromJson(json))
          .toList();
    } catch (e) {
      throw ApplicationServiceException('Failed to fetch applications to my posts: $e');
    }
  }
}

/// Exception for application service errors
class ApplicationServiceException implements Exception {
  final String message;
  ApplicationServiceException(this.message);
  
  @override
  String toString() => 'ApplicationServiceException: $message';
}
