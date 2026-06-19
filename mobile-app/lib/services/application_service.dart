import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/api_config.dart';
import '../models/post_model.dart';

/// Service for handling job/post applications with Supabase. Uses real user ids.
class ApplicationService {
  static SupabaseClient get _client => Supabase.instance.client;

  static const _applicationsSelect = '*, users(name, email, profile_image, avatar_url)';

  // PostgreSQL unique-violation error code.
  static const _pgUniqueViolation = '23505';

  /// Submit an application. Requires [currentUserId]. Name/avatar come from users join on read.
  /// Throws [DuplicateApplicationException] if the user has already applied to this post.
  static Future<Application> submitApplication({
    required String postId,
    required String currentUserId,
    required String message,
    required double proposedPrice,
  }) async {
    if (currentUserId.isEmpty) {
      throw ApplicationServiceException('Sign in to submit an application.');
    }

    // Layer B: check before insert so the caller can show a clean message
    // without relying solely on the DB constraint.
    final alreadyApplied = await hasApplied(postId, currentUserId);
    if (alreadyApplied) {
      throw DuplicateApplicationException();
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
      debugPrint('[APPLICATIONS][INSERT] postId=$postId applicantId=$currentUserId');

      // Fire-and-forget: notify post author that someone applied.
      _notifyApplication(postId: postId, applicantUserId: currentUserId);

      return app;
    } catch (e) {
      // Layer B fallback: DB unique constraint fired (race condition between check and insert).
      final eStr = e.toString();
      if (eStr.contains(_pgUniqueViolation) ||
          eStr.contains('uq_applications_post_applicant') ||
          eStr.contains('duplicate key')) {
        throw DuplicateApplicationException();
      }
      debugPrint('❌ Application submit failed: $e');
      throw ApplicationServiceException('Failed to submit application: $e');
    }
  }

  /// Fire-and-forget: tells the backend to send a notification to the post author.
  /// Failures are swallowed — the application was already submitted successfully.
  static void _notifyApplication({
    required String postId,
    required String applicantUserId,
  }) {
    http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/jobs/notify-application'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'post_id': postId,
            'applicant_user_id': applicantUserId,
          }),
        )
        .timeout(const Duration(seconds: 10))
        .then((res) {
          debugPrint('[APPLICATIONS][REALTIME] notify-application status=${res.statusCode}');
        })
        .catchError((e) {
          debugPrint('[APPLICATIONS][REALTIME] notify-application error: $e');
        });
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
          .eq('author_user_id', currentUserId)
          .filter('archived_at', 'is', null); // exclude archived posts

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

/// Thrown when a user tries to apply to a post they have already applied to.
class DuplicateApplicationException implements Exception {
  @override
  String toString() => 'DuplicateApplicationException: already applied to this post';
}
