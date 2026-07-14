import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';

import '../models/post_model.dart';
import '../services/user_profile_service.dart';
import '../theme/app_theme.dart';
import '../widgets/loading_empty_offline.dart';
import '../widgets/post_card.dart';
import 'job_lifecycle_screen.dart';

/// The profile's activity-management surface: every post the user has
/// authored (requests, offers and job posts), newest first, rendered with the
/// standard feed card. Tapping a post opens the Job Lifecycle Detail — the
/// single management view for status, payment, completion and disputes.
class MyPostsScreen extends StatefulWidget {
  final String userId;

  const MyPostsScreen({super.key, required this.userId});

  @override
  State<MyPostsScreen> createState() => _MyPostsScreenState();
}

class _MyPostsScreenState extends State<MyPostsScreen> {
  late Future<List<PostModel>> _future;

  @override
  void initState() {
    super.initState();
    _future = UserProfileService.getAuthoredPosts(widget.userId);
  }

  Future<void> _refresh() async {
    final next = UserProfileService.getAuthoredPosts(widget.userId);
    setState(() => _future = next);
    await next.catchError((_) => const <PostModel>[]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Posts')),
      body: FutureBuilder<List<PostModel>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const FeedSkeletonList();
          }
          if (snap.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.cloud_off_rounded,
                      size: 40,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? AppTheme.darkTextTertiary
                          : AppTheme.lightTextTertiary),
                  const SizedBox(height: 12),
                  const Text("Couldn't load your posts."),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            );
          }
          final posts = snap.data ?? const [];
          if (posts.isEmpty) {
            return const EmptyStateView(
              icon: Iconsax.document_text,
              title: 'No posts yet',
              subtitle:
                  'Your requests, offers and job posts will appear here so you can manage them.',
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              itemCount: posts.length,
              itemBuilder: (context, i) {
                final post = posts[i];
                return PostCard(
                  post: post,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => JobLifecycleScreen(postId: post.id),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
