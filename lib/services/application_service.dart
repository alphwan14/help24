import '../config/supabase_config.dart';
import '../models/post_model.dart';
import '../utils/guest_id.dart';

/// Service for handling job/post applications with Supabase
class ApplicationService {
  static final _client = SupabaseConfig.client;

  /// Submit an application to a post
  static Future<Application> submitApplication({
    required String postId,
    required String message,
    required double proposedPrice,
    String? applicantName,
  }) async {
    try {
      final guestId = GuestId.currentId;
      final name = applicantName ?? GuestId.currentName;

      final applicationData = {
        'post_id': postId,
        'applicant_name': name,
        'applicant_temp_id': guestId,
        'message': message,
        'proposed_price': proposedPrice,
      };

      final response = await _client
          .from('applications')
          .insert(applicationData)
          .select()
          .single();

      return Application.fromJson(response);
    } catch (e) {
      throw ApplicationServiceException('Failed to submit application: $e');
    }
  }

  /// Get all applications for a specific post
  static Future<List<Application>> getApplicationsForPost(String postId) async {
    try {
      final response = await _client
          .from('applications')
          .select()
          .eq('post_id', postId)
          .order('created_at', ascending: false);

      return (response as List)
          .map((json) => Application.fromJson(json))
          .toList();
    } catch (e) {
      throw ApplicationServiceException('Failed to fetch applications: $e');
    }
  }

  /// Get all applications submitted by the current guest user
  static Future<List<Application>> getMyApplications() async {
    try {
      final guestId = GuestId.currentId;

      final response = await _client
          .from('applications')
          .select()
          .eq('applicant_temp_id', guestId)
          .order('created_at', ascending: false);

      return (response as List)
          .map((json) => Application.fromJson(json))
          .toList();
    } catch (e) {
      throw ApplicationServiceException('Failed to fetch my applications: $e');
    }
  }

  /// Check if current user has already applied to a post
  static Future<bool> hasApplied(String postId) async {
    try {
      final guestId = GuestId.currentId;

      final response = await _client
          .from('applications')
          .select('id')
          .eq('post_id', postId)
          .eq('applicant_temp_id', guestId)
          .maybeSingle();

      return response != null;
    } catch (e) {
      return false;
    }
  }

  /// Delete an application (only if it belongs to current user)
  static Future<void> deleteApplication(String applicationId) async {
    try {
      final guestId = GuestId.currentId;

      await _client
          .from('applications')
          .delete()
          .eq('id', applicationId)
          .eq('applicant_temp_id', guestId);
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

  /// Get applications for posts owned by current user
  static Future<List<Application>> getApplicationsToMyPosts() async {
    try {
      final guestId = GuestId.currentId;

      // First get post IDs owned by current user
      final postsResponse = await _client
          .from('posts')
          .select('id')
          .eq('author_temp_id', guestId);

      if ((postsResponse as List).isEmpty) {
        return [];
      }

      final postIds = postsResponse
          .map((p) => p['id'] as String)
          .toList();

      // Then get applications for those posts
      final response = await _client
          .from('applications')
          .select()
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
