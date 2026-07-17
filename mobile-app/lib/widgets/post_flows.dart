import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../screens/messages_screen.dart';
import '../services/application_service.dart';
import '../services/post_service.dart';
import '../services/user_profile_service.dart';
import '../theme/app_theme.dart';
import 'application_modal.dart';

/// Shared post action flows — used by both the feed cards (discover) and the
/// post detail screen so the business rules (duplicate-application guard,
/// M-Pesa requirement, pending-conversation pattern) live in exactly one place.

/// Confirm + archive the current user's post. Returns true when the post was
/// deleted (caller decides whether to pop a screen); shows result snackbars on
/// the app-wide messenger either way.
Future<bool> confirmAndDeletePost(BuildContext context, PostModel post) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete post?'),
      content: const Text(
        'This will permanently delete your post and its images. This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('Delete',
              style: TextStyle(color: AppTheme.errorRed, fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  final appProvider = context.read<AppProvider>();
  final currentUserId = context.read<AuthProvider>().currentUserId;
  final success = await appProvider.deletePost(post.id, currentUserId);
  if (!context.mounted) return success;
  if (success) {
    await appProvider.loadPosts();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 12),
              Text('Post deleted'),
            ],
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.successGreen,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(appProvider.error ?? 'Failed to delete post'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.errorRed,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
  return success;
}

/// Open private chat with the post author. No public application list;
/// messages only in the Messages tab. The chat row is created on first send.
Future<void> openPrivateChat(BuildContext context, PostModel post) async {
  final currentUserId = context.read<AuthProvider>().currentUserId ?? '';
  if (currentUserId.isEmpty) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Please sign in to message providers'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }

  String authorId = post.authorUserId;
  if (authorId.isEmpty) {
    // Fallback for older/inconsistent rows where feed payload lacks author_user_id.
    try {
      final freshPost = await PostService.getPostById(post.id);
      authorId = freshPost?.authorUserId ?? '';
    } catch (_) {
      authorId = '';
    }
  }

  if (authorId.isEmpty) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Unable to contact this provider right now'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }

  if (authorId == currentUserId) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('This is your own post'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }

  // Build a pending Conversation — no DB row until first message is sent.
  final conv = Conversation(
    id: '',
    participantId: authorId,
    userName: post.authorName,
    userAvatar: post.authorAvatar,
    lastMessage: '',
    lastMessageTime: DateTime.now(),
    postId: post.id,
    postTitle: post.title,
  );
  if (!context.mounted) return;
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (c) => ChatScreen(conversation: conv, currentUserId: currentUserId),
    ),
  );
}

/// Open ApplicationModal to let a user offer service on a request.
Future<void> openOfferServiceModal(BuildContext context, PostModel post) async {
  final currentUserId = context.read<AuthProvider>().currentUserId ?? '';
  if (currentUserId.isEmpty) return;

  if (post.authorUserId == currentUserId) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('This is your own request'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }

  // Layer C (frontend): guard — prevent duplicate application before showing modal.
  final alreadyApplied = await ApplicationService.hasApplied(post.id, currentUserId);
  if (!context.mounted) return;
  if (alreadyApplied) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.info_outline_rounded, color: Colors.white, size: 18),
            SizedBox(width: 10),
            Flexible(child: Text('You already applied to this request.')),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
    return;
  }

  // Providers must have an M-Pesa number so they can receive payment when selected.
  final phone = await UserProfileService.getMpesaPhone(currentUserId);
  if (!context.mounted) return;
  if (phone == null || phone.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.phone_android_rounded, color: Colors.white, size: 18),
            SizedBox(width: 10),
            Flexible(
              child: Text(
                'Add your M-Pesa number in Profile → Payment Settings to offer services.',
              ),
            ),
          ],
        ),
        backgroundColor: AppTheme.warningOrange,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 4),
      ),
    );
    return;
  }

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ApplicationModal(
      title: post.title,
      type: 'request',
      onSubmit: (message) async {
        try {
          await ApplicationService.submitApplication(
            postId: post.id,
            currentUserId: currentUserId,
            message: message,
            proposedPrice: 0,
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.white),
                    SizedBox(width: 12),
                    Text('Offer sent!'),
                  ],
                ),
                behavior: SnackBarBehavior.floating,
                backgroundColor: AppTheme.successGreen,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            );
          }
        } on DuplicateApplicationException {
          // Race condition: user applied between the pre-check and the insert.
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Row(
                  children: [
                    Icon(Icons.info_outline_rounded, color: Colors.white, size: 18),
                    SizedBox(width: 10),
                    Flexible(child: Text('You already applied to this request.')),
                  ],
                ),
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            );
          }
          rethrow; // Causes ApplicationModal to reset its spinner instead of popping.
        }
      },
    ),
  );
}

/// Open a chat with a specific user (e.g. an applicant). Passes name/avatar so
/// the header renders immediately without a DB fetch. Chat row created on first send.
Future<void> openChatWithUser(
  BuildContext context,
  String postId,
  String otherUserId, {
  String otherUserName = '',
  String otherUserAvatar = '',
}) async {
  final currentUserId = context.read<AuthProvider>().currentUserId ?? '';
  if (currentUserId.isEmpty || otherUserId.isEmpty) return;
  final conv = Conversation(
    id: '',
    participantId: otherUserId,
    userName: otherUserName.isNotEmpty ? otherUserName : 'User',
    userAvatar: otherUserAvatar,
    lastMessage: '',
    lastMessageTime: DateTime.now(),
    postId: postId,
  );
  if (!context.mounted) return;
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (c) => ChatScreen(conversation: conv, currentUserId: currentUserId),
    ),
  );
}
