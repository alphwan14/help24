import 'package:cloud_firestore/cloud_firestore.dart';
import '../config/supabase_config.dart';
import '../models/post_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Public comments on posts. Firestore: posts/{postId}/comments/{commentId}.
/// Fields: userId, text, timestamp, userName (optional, for display).
/// Comments = public discussion. Never mixed with private messages.
class CommentServiceFirestore {
  static FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  static SupabaseClient get _supabase => SupabaseConfig.client;

  /// Real-time stream of comments for a post. Use for post details page.
  static Stream<List<PostComment>> watchComments(String postId) {
    if (postId.isEmpty) return Stream.value([]);
    return _firestore
        .collection('posts')
        .doc(postId)
        .collection('comments')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map((snap) => snap.docs.map((d) => _commentFromFirestore(d, postId)).toList());
  }

  static PostComment _commentFromFirestore(DocumentSnapshot d, String postId) {
    final data = d.data() as Map<String, dynamic>? ?? {};
    final ts = data['timestamp'] is Timestamp
        ? (data['timestamp'] as Timestamp).toDate()
        : DateTime.now();
    return PostComment(
      id: d.id,
      postId: postId,
      userId: data['userId']?.toString() ?? '',
      userName: data['userName']?.toString() ?? '?',
      text: data['text']?.toString() ?? '',
      timestamp: ts,
    );
  }

  /// Add a public comment. Requires auth. Fetches current user name from Supabase for display.
  static Future<PostComment> addComment({
    required String postId,
    required String userId,
    required String text,
  }) async {
    if (postId.isEmpty || userId.isEmpty || text.trim().isEmpty) {
      throw CommentServiceException('Post id, user id and text are required.');
    }
    final trimmed = text.trim();
    final userName = await _getUserName(userId);
    final now = DateTime.now();

    final ref = _firestore.collection('posts').doc(postId).collection('comments').doc();
    await ref.set({
      'userId': userId,
      'userName': userName,
      'text': trimmed,
      'timestamp': Timestamp.fromDate(now),
    });

    return PostComment(
      id: ref.id,
      postId: postId,
      userId: userId,
      userName: userName,
      text: trimmed,
      timestamp: now,
    );
  }

  static Future<String> _getUserName(String userId) async {
    if (userId.isEmpty) return '?';
    try {
      final r = await _supabase.from('users').select('name, email').eq('id', userId).maybeSingle();
      if (r != null) {
        final name = r['name']?.toString()?.trim();
        if (name != null && name.isNotEmpty) return name;
        final email = r['email']?.toString()?.trim();
        if (email != null && email.isNotEmpty) {
          final prefix = email.split('@').first.trim();
          return prefix.isNotEmpty ? prefix : '?';
        }
      }
    } catch (_) {}
    return '?';
  }
}

class CommentServiceException implements Exception {
  final String message;
  CommentServiceException(this.message);
  @override
  String toString() => 'CommentServiceException: $message';
}
