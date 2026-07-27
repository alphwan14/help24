import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../screens/messages_screen.dart';
import '../screens/post_detail_screen.dart';
import '../services/application_service.dart';
import '../services/interaction_tracker.dart';
import '../services/post_service.dart';
import '../theme/app_theme.dart';
import '../utils/action_feedback.dart';
import '../utils/error_mapper.dart';
import '../utils/post_ownership.dart';
import 'application_modal.dart';
import 'provider_gate.dart';

/// Shared post action flows — used by both the feed cards (discover) and the
/// post detail screen so the business rules (duplicate-application guard,
/// M-Pesa requirement, pending-conversation pattern) live in exactly one place.

/// Why a listing can no longer be responded to, as one plain sentence — or null
/// while it is still open.
///
/// One definition, read by the feed (to answer in place) and by the detail
/// screen's action bar (to replace its CTA), so the two can never disagree
/// about what a status means.
String? closedListingReason(PostModel post) {
  if (post.status == 'open') return null;
  if (post.status == 'completed') {
    return post.payoutInProgress
        ? 'This job is completed — payment is being finalised.'
        : 'This job is completed.';
  }
  if (post.status == 'disputed') return 'This job is in dispute.';
  if (post.status == 'cancelled') return 'This listing was closed.';
  return 'This request already has a provider.';
}

/// Open a post from a BROWSING surface (the Discover feed).
///
/// WHY THIS IS NOT JUST `Navigator.push`
/// -------------------------------------
/// Tapping a completed or already-taken listing used to push the full detail
/// screen, whose entire answer was a single sentence in the action bar. The
/// user paid a screen transition, lost their place in the feed, read one line,
/// and pressed Back. An informational state should never cost the user their
/// context.
///
/// So: a closed listing answers IN PLACE and the feed stays exactly where it
/// was — same scroll offset, same filters, same search. The detail screen is
/// still reachable on purpose (the "View" action), because "don't interrupt
/// browsing" must not become "you may never look at this".
///
/// People with real business on the post — its author, and the provider who was
/// selected for it — always get the full screen, since theirs has actions on it.
void openPostFromFeed(BuildContext context, PostModel post) {
  final uid = context.read<AuthProvider>().currentUserId ?? '';
  final reason = inPlaceAnswerFor(post, uid);

  if (reason == null) {
    _pushPostDetail(context, post);
    return;
  }

  ActionFeedback.info(
    context,
    reason,
    actionLabel: 'View',
    onAction: () => _pushPostDetail(context, post),
  );
}

/// What a tap on [post] should say instead of navigating — or null when the
/// tap should open the post normally.
///
/// Separated from the navigation so the rule is decidable (and testable)
/// without building the detail screen.
String? inPlaceAnswerFor(PostModel post, String viewerUserId) {
  final reason = closedListingReason(post);
  if (reason == null) return null;
  // The owner and the selected provider always get the full screen — theirs has
  // actions on it. `isListingOwner` is the shared rule: an empty uid must not
  // match an empty authorUserId on a legacy row and hand a signed-out browser
  // the owner's screen.
  if (isListingOwner(
        authorUserId: post.authorUserId,
        viewerUserId: viewerUserId,
      ) ||
      (viewerUserId.isNotEmpty &&
          post.selectedProviderUserId == viewerUserId)) {
    return null;
  }
  return reason;
}

void _pushPostDetail(BuildContext context, PostModel post) {
  // Recorded HERE rather than in each caller, because this is the one place
  // every entry point converges: Discover, Jobs, Saved, My Posts, deep links.
  // An `open` is the clearest evidence of interest short of applying, and
  // ranking signal 9 reads it back as category, profession and author affinity.
  InteractionTracker.instance.trackOpen(post);
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => PostDetailScreen(post: post)),
  );
}

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
    // Job posts live in their own list (the Jobs tab reads `jobs`, not
    // `posts`), so reloading only posts left a deleted job on screen. Deleting
    // now happens on the shared detail screen for every type, so this has to
    // refresh whichever list the listing came from.
    await (post.type == PostType.job
        ? appProvider.loadJobs()
        : appProvider.loadPosts());
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
///
/// Wrapped for the same reason as [openOfferServiceModal]: it is invoked as a
/// `VoidCallback`, so an escaping exception would be discarded unseen.
Future<void> openPrivateChat(BuildContext context, PostModel post) async {
  try {
    await _openPrivateChat(context, post);
  } catch (e) {
    if (!context.mounted) {
      debugPrint('[POST_FLOWS] open chat failed after unmount: $e');
      return;
    }
    ActionFeedback.failure(context, e, context_: ErrorContext.sendMessage);
  }
}

Future<void> _openPrivateChat(BuildContext context, PostModel post) async {
  final currentUserId = context.read<AuthProvider>().currentUserId ?? '';
  if (currentUserId.isEmpty) {
    ActionFeedback.info(context, 'Please sign in to message providers');
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

  if (!context.mounted) return;
  if (authorId.isEmpty) {
    ActionFeedback.info(context, 'Unable to contact this provider right now');
    return;
  }

  if (authorId == currentUserId) {
    ActionFeedback.info(context, 'This is your own post');
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
  // Reaching a chat about a listing is a strong intent signal (weight 4) — the
  // step before hiring. Recorded once the destination is certain, not on the
  // tap that might still bounce off a guard above.
  InteractionTracker.instance.trackMessage(post);
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (c) => ChatScreen(conversation: conv, currentUserId: currentUserId),
    ),
  );
}

/// Open the OWNER's management experience for [post].
///
/// The single entry point for "this is mine, let me manage it", called from
/// Discover, the Jobs tab and Profile → My Posts. All three used to go
/// somewhere different: Discover pushed the detail screen (which showed a job
/// author nothing but "You posted this job"), the Jobs tab opened a private
/// bottom sheet with an Apply button on it, and My Posts jumped straight to the
/// lifecycle view. One destination now, so arriving from a different screen can
/// never mean a different experience.
void openListingManagement(BuildContext context, PostModel post) =>
    _pushPostDetail(context, post);

/// Open ApplicationModal so a user can respond to a listing that takes
/// applications — offering service on a request, or applying to a job post.
///
/// THE ONLY APPLY PATH. The Jobs tab used to build its own, which skipped the
/// ownership and duplicate checks this one performs; pressing Apply on your own
/// job therefore reached the database, hit the `trg_block_self_application`
/// trigger, and surfaced as the generic "We couldn't send your response."
/// Everything routes here now, so the guards cannot be bypassed by arriving
/// from a different screen.
///
/// Invoked from `onAuthenticated:` callbacks typed as `VoidCallback`, so the
/// returned Future is discarded by the framework and any throw becomes an
/// unhandled async error — invisible. The whole body is therefore wrapped: an
/// exception on the way to the modal is reported, never dropped.
Future<void> applyToListing(BuildContext context, PostModel post) async {
  try {
    await _applyToListing(context, post);
  } catch (e) {
    if (!context.mounted) {
      debugPrint('[POST_FLOWS] apply flow failed after unmount: $e');
      return;
    }
    ActionFeedback.failure(context, e, context_: ErrorContext.apply);
  }
}

Future<void> _applyToListing(BuildContext context, PostModel post) async {
  final isJob = post.type == PostType.job;
  final currentUserId = context.read<AuthProvider>().currentUserId ?? '';
  if (currentUserId.isEmpty) {
    // Previously a bare `return` — a tap that produced nothing at all.
    ActionFeedback.info(
      context,
      isJob ? 'Please sign in to apply' : 'Please sign in to offer your services',
    );
    return;
  }

  // Ownership first, and before ANY network call. The CTAs above this point
  // already refuse to offer Apply to an author; this is the guard for every
  // path that reaches the flow anyway (deep link, stale card, race).
  if (isListingOwner(
    authorUserId: post.authorUserId,
    viewerUserId: currentUserId,
  )) {
    ActionFeedback.info(
      context,
      isJob ? 'This is your own job post' : 'This is your own request',
      actionLabel: 'Manage',
      onAction: () => openListingManagement(context, post),
    );
    return;
  }

  // Layer C (frontend): guard — prevent duplicate application before showing modal.
  final alreadyApplied = await ApplicationService.hasApplied(post.id, currentUserId);
  if (!context.mounted) return;
  if (alreadyApplied) {
    ActionFeedback.info(
      context,
      isJob ? 'You already applied to this job.' : 'You already applied to this request.',
    );
    return;
  }

  // Become-a-provider gate: a confirmed profession (so the client knows who
  // they are hiring) AND an M-Pesa number (so the provider can be paid). One
  // gate for both listing kinds — see widgets/provider_gate.dart.
  final ready = await ensureProviderReady(
    context,
    uid: currentUserId,
    action: isJob ? 'apply for jobs' : 'offer your services',
  );
  if (!context.mounted || !ready) return;

  // Captured before the sheet: the modal's callback outlives this context.
  final appProvider = context.read<AppProvider>();

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ApplicationModal(
        title: post.title,
        type: isJob ? 'job' : 'request',
        // Does the work and nothing else. Success and every failure — including
        // the duplicate-application race, which ErrorMapper renders as "You've
        // already applied" — are reported by the modal. See its class comment for
        // why this used to be split across both sides and reported by neither.
        onSubmit: (message) async {
          await ApplicationService.submitApplication(
            postId: post.id,
            currentUserId: currentUserId,
            message: message,
            proposedPrice: 0,
            postAuthorUserId: post.authorUserId,
          );
          // Only after a successful write: the card flips to its done state
          // immediately instead of waiting for the next loadMyApplications.
          appProvider.markApplied(post.id);
          // Also only after a successful write — an abandoned modal is not an
          // application, and must not train the feed as though it were.
          InteractionTracker.instance.trackApply(post);
        },
      ),
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
  String postTitle = '',
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
    postId: postId.isNotEmpty ? postId : null,
    // Without the title the chat renders no post banner and no View post /
    // Job status menu entries — pass it whenever the caller knows it.
    postTitle: postTitle.isNotEmpty ? postTitle : null,
  );
  if (!context.mounted) return;
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (c) => ChatScreen(conversation: conv, currentUserId: currentUserId),
    ),
  );
}
