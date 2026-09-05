import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';

import '../models/post_model.dart';
import '../services/user_profile_service.dart';
import '../theme/app_theme.dart';
import '../widgets/loading_empty_offline.dart';
import '../widgets/post_card.dart';
import '../widgets/post_flows.dart';

/// The profile's activity-management surface: every post the user has
/// authored (requests, offers and job posts), newest first, rendered with the
/// standard feed card.
///
/// Tapping a post opens [openListingManagement] — the same canonical detail
/// screen Discover and the Jobs tab open. This screen used to jump straight to
/// the Job Lifecycle Detail, which meant the owner of one job saw applicants
/// from one entry point and a payment timeline from another. The lifecycle view
/// is now one tap further in, on the listing itself, where both roles can reach
/// it.
///
/// SEARCH IS A FILTER OVER WHAT IS ALREADY HERE, NOT A QUERY.
/// [UserProfileService.getAuthoredPosts] returns the author's whole history in
/// one call and there is no pagination, so every post the search can match is
/// already in memory. Typing therefore costs nothing: no request, no loading
/// state, no way for the list to disagree with itself mid-keystroke. It matches
/// TITLE and PROFESSION because those are the two things an author actually
/// remembers a post by — description is long free text that makes a short query
/// match almost everything, and location is already how the cards read.
class MyPostsScreen extends StatefulWidget {
  final String userId;

  const MyPostsScreen({super.key, required this.userId});

  @override
  State<MyPostsScreen> createState() => _MyPostsScreenState();
}

class _MyPostsScreenState extends State<MyPostsScreen> {
  late Future<List<PostModel>> _future;
  final _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = UserProfileService.getAuthoredPosts(widget.userId);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final next = UserProfileService.getAuthoredPosts(widget.userId);
    setState(() => _future = next);
    await next.catchError((_) => const <PostModel>[]);
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
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
          final posts = snap.data ?? const <PostModel>[];
          // Nothing authored yet is a different situation from "nothing
          // matches", and it gets the empty state rather than a search box over
          // an empty list.
          if (posts.isEmpty) {
            return const EmptyStateView(
              icon: Iconsax.document_text,
              title: 'No posts yet',
              subtitle:
                  'Your requests, offers and job posts will appear here so you can manage them.',
            );
          }
          final visible = searchAuthoredPosts(posts, _query);
          return Column(
            children: [
              _SearchField(
                controller: _search,
                hasQuery: _query.isNotEmpty,
                onChanged: (v) {
                  if (v == _query) return;
                  setState(() => _query = v);
                },
                onClear: _clearSearch,
              ),
              Expanded(
                // Pull-to-refresh stays available while filtered, so the list
                // is never a dead end — hence a scrollable no-match state
                // rather than a centred Column.
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: visible.isEmpty
                      ? ListView(
                          padding: const EdgeInsets.fromLTRB(32, 64, 32, 24),
                          children: [
                            _NoMatches(query: _query, onClear: _clearSearch),
                          ],
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                          itemCount: visible.length,
                          itemBuilder: (context, i) {
                            final post = visible[i];
                            return PostCard(
                              post: post,
                              onTap: () => openListingManagement(context, post),
                            );
                          },
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final bool hasQuery;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SearchField({
    required this.controller,
    required this.hasQuery,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: TextField(
        controller: controller,
        textInputAction: TextInputAction.search,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: 'Search by title or profession',
          isDense: true,
          prefixIcon: Icon(
            Iconsax.search_normal,
            size: 18,
            color:
                isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
          ),
          suffixIcon: hasQuery
              ? IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: 'Clear search',
                  onPressed: onClear,
                )
              : null,
        ),
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  final String query;
  final VoidCallback onClear;

  const _NoMatches({required this.query, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tertiary =
        isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    return Column(
      children: [
        Icon(Iconsax.search_normal, size: 34, color: tertiary),
        const SizedBox(height: 14),
        Text(
          'No posts match "$query"',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Text(
          'Search looks at the title and the profession.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 14),
        TextButton.icon(
          onPressed: onClear,
          icon: const Icon(Icons.close_rounded, size: 18),
          label: const Text('Clear search'),
        ),
      ],
    );
  }
}

/// Filter an author's own posts by [query], matching TITLE or PROFESSION.
///
/// Case-insensitive, and whitespace is collapsed so a stray double space still
/// finds the post. An empty query is the identity: it returns the same list,
/// which is what makes clearing the box restore everything for free.
///
/// Deliberately does NOT search description or location. A short query against
/// long free text matches almost every post, which is worse than no search at
/// all; location is already how the cards read.
List<PostModel> searchAuthoredPosts(List<PostModel> posts, String query) {
  final q = query.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (q.isEmpty) return posts;
  return posts
      .where((p) =>
          p.title.toLowerCase().contains(q) ||
          p.category.name.toLowerCase().contains(q))
      .toList();
}
