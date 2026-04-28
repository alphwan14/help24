import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/connectivity_provider.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import '../utils/time_utils.dart';
import '../widgets/loading_empty_offline.dart';
import '../widgets/post_card.dart';
import '../widgets/filter_bottom_sheet.dart';
import '../widgets/auth_guard.dart';
import '../providers/auth_provider.dart';
import '../services/comment_service_firestore.dart';
import '../services/post_service.dart';
import 'messages_screen.dart';
import 'urgent_requests_screen.dart';
import 'payment_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final TextEditingController _searchController = TextEditingController();

  // 0 = All, 1 = Requests, 2 = Offers
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppProvider>().setSelectedFilter('All');
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refreshPosts() async {
    await context.read<AppProvider>().loadPosts();
  }

  void _switchToTab(int tab) {
    if (_tabIndex == tab) return;
    _searchController.clear();
    setState(() => _tabIndex = tab);
    final provider = context.read<AppProvider>();
    provider.setSearchQuery('');
    const filters = ['All', 'Requests', 'Offers'];
    provider.setSelectedFilter(filters[tab]);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final searchText = _searchController.text;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Top bar ──────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Discover',
                    style: Theme.of(context).textTheme.headlineMedium),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const UrgentRequestsScreen()),
                  ),
                  child: const Text('Urgent'),
                ),
              ],
            ),
          ),

          // ── Search bar ───────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
            child: Consumer<AppProvider>(
              builder: (context, provider, _) {
                return TextField(
                  controller: _searchController,
                  onChanged: provider.setSearchQuery,
                  decoration: InputDecoration(
                    hintText: _tabIndex == 0
                        ? 'Search all posts...'
                        : _tabIndex == 1
                            ? 'Search requests...'
                            : 'Search offers...',
                    prefixIcon: Icon(
                      Iconsax.search_normal,
                      color: isDark
                          ? AppTheme.darkTextTertiary
                          : AppTheme.lightTextTertiary,
                    ),
                    suffixIcon: searchText.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () {
                              _searchController.clear();
                              provider.setSearchQuery('');
                            },
                          )
                        : null,
                  ),
                );
              },
            ),
          ),

          // ── Tabs (left) + Filter button (right) in one row ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Consumer<AppProvider>(
              builder: (context, provider, _) {
                return Row(
                  children: [
                    _TabItem(
                      label: 'All',
                      isActive: _tabIndex == 0,
                      onTap: () => _switchToTab(0),
                    ),
                    const SizedBox(width: 20),
                    _TabItem(
                      label: 'Requests',
                      isActive: _tabIndex == 1,
                      onTap: () => _switchToTab(1),
                    ),
                    const SizedBox(width: 20),
                    _TabItem(
                      label: 'Offers',
                      isActive: _tabIndex == 2,
                      onTap: () => _switchToTab(2),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () async {
                        await showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          builder: (context) => DraggableScrollableSheet(
                            initialChildSize: 0.85,
                            minChildSize: 0.5,
                            maxChildSize: 0.95,
                            builder: (context, scrollController) =>
                                const FilterBottomSheet(),
                          ),
                        );
                        if (mounted) provider.applyFilters();
                      },
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: provider.hasActiveFilters
                              ? AppTheme.primaryAccent.withValues(alpha: 0.12)
                              : (isDark
                                  ? AppTheme.darkCard
                                  : AppTheme.lightCard),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: provider.hasActiveFilters
                                ? AppTheme.primaryAccent
                                : (isDark
                                    ? AppTheme.darkBorder
                                    : AppTheme.lightBorder),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Iconsax.filter,
                              size: 18,
                              color: provider.hasActiveFilters
                                  ? AppTheme.primaryAccent
                                  : (isDark
                                      ? AppTheme.darkTextPrimary
                                      : AppTheme.lightTextPrimary),
                            ),
                            if (provider.hasActiveFilters) ...[
                              const SizedBox(width: 6),
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: AppTheme.primaryAccent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),

          const SizedBox(height: 4),

          // ── Context label (only when user has typed something) ─
          if (searchText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Text(
                'Showing ${_tabIndex == 0 ? 'all posts' : _tabIndex == 1 ? 'requests' : 'offers'} for "$searchText"',
                style: TextStyle(
                  color: textSecondary,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),

          const SizedBox(height: 8),

          // ── Feed ─────────────────────────────────────────────
          Expanded(
            child: _buildPostsFeed(),
          ),
        ],
      ),
    );
  }

  // ── Feed widgets ────────────────────────────────────────────────

  Widget _buildPostsFeed() {
    return Consumer2<AppProvider, ConnectivityProvider>(
      builder: (context, provider, connectivity, _) {
        final posts = provider.filteredPosts;

        if (provider.isLoadingPosts && posts.isEmpty) {
          return const FeedSkeletonList();
        }

        if (posts.isEmpty) {
          if (connectivity.isOffline) {
            return OfflineEmptyView(
              message: 'No internet connection',
              onRetry: () {
                connectivity.checkNow();
                _refreshPosts();
              },
            );
          }
          return EmptyStateView(
            icon: Iconsax.document,
            title: 'No posts found',
            subtitle: provider.error ??
                'Try adjusting your filters or search. Pull to refresh.',
            actions: [
              TextButton.icon(
                onPressed: _refreshPosts,
                icon: const Icon(Icons.refresh, size: 20),
                label: const Text('Refresh'),
              ),
              if (provider.hasActiveFilters)
                TextButton.icon(
                  onPressed: () => provider.clearFilters(),
                  icon: const Icon(Iconsax.close_circle, size: 20),
                  label: const Text('Clear Filters'),
                ),
            ],
          );
        }

        return RefreshIndicator(
          onRefresh: _refreshPosts,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: posts.length,
            itemBuilder: (context, index) {
              final post = posts[index];
              return PostCard(
                post: post,
                onTap: () => _showPostDetails(context, post),
                onRespond: post.type == PostType.request
                    ? () {
                        AuthGuard.requireAuth(
                          context,
                          action: 'offer help on this request',
                          onAuthenticated: () =>
                              _openPrivateChat(context, post),
                        );
                      }
                    : null,
              );
            },
          ),
        );
      },
    );
  }

  void _showPostDetails(BuildContext context, PostModel post) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // Consumer wrapping makes isAuthor & offline reactive — no stale captures.
      builder: (sheetContext) => Consumer2<AuthProvider, ConnectivityProvider>(
        builder: (_, auth, connectivity, __) {
          final currentUserId = auth.currentUserId ?? '';
          final isAuthor = currentUserId.isNotEmpty &&
              post.authorUserId.isNotEmpty &&
              post.authorUserId == currentUserId;
          final isOffline = connectivity.isOffline;

          // Secure Service is only available on Request posts where the author
          // has already selected a provider. Never shown on Offer posts.
          final showPayButton = post.type == PostType.request &&
              isAuthor &&
              post.selectedProviderUserId != null &&
              post.price > 0;

          return Container(
            height: MediaQuery.of(sheetContext).size.height * 0.85,
            decoration: BoxDecoration(
              color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: Icon(Icons.close,
                            color: isDark
                                ? AppTheme.darkTextPrimary
                                : AppTheme.lightTextPrimary),
                        onPressed: () => Navigator.pop(sheetContext),
                      ),
                      if (isAuthor)
                        TextButton.icon(
                          onPressed: () => _confirmAndDeletePost(
                              sheetContext, context, post),
                          icon: Icon(Icons.delete_outline,
                              size: 20, color: AppTheme.errorRed),
                          label: Text('Delete',
                              style: TextStyle(
                                  color: AppTheme.errorRed,
                                  fontWeight: FontWeight.w600)),
                        )
                      else
                        const SizedBox(width: 48),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Images
                        if (post.images.isNotEmpty) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: SizedBox(
                              height: 200,
                              width: double.infinity,
                              child: PageView.builder(
                                itemCount: post.images.length,
                                itemBuilder: (context, index) {
                                  return Image.network(
                                    post.images[index],
                                    fit: BoxFit.cover,
                                    errorBuilder:
                                        (context, error, stackTrace) {
                                      return Container(
                                        color: AppTheme.darkCard,
                                        child: const Icon(
                                            Icons.image_not_supported),
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],

                        // Header
                        Row(
                          children: [
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: AppTheme.primaryAccent
                                    .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Icon(
                                post.category.icon,
                                color: AppTheme.primaryAccent,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    post.title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall,
                                  ),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 4,
                                    children: [
                                      _BadgeChip(
                                        label: post.category.name,
                                        color: AppTheme.primaryAccent,
                                      ),
                                      _BadgeChip(
                                        label: post.typeDisplayLabel,
                                        color: post.typeBadgeColor,
                                      ),
                                      if (post.type == PostType.offer)
                                        _BadgeChip(
                                          label: '✔ Provider',
                                          color: AppTheme.successGreen,
                                        ),
                                      _BadgeChip(
                                        label: post.urgencyText,
                                        color: post.urgencyColor,
                                        dot: true,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),

                        // Description
                        Text('Description',
                            style:
                                Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 8),
                        Text(post.description,
                            style: Theme.of(context).textTheme.bodyLarge),
                        const SizedBox(height: 24),

                        // Details grid
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isDark
                                ? AppTheme.darkCard
                                : AppTheme.lightBackground,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            children: [
                              _DetailRow(
                                icon: Icons.location_on_outlined,
                                label: 'Location',
                                value: post.location,
                              ),
                              const Divider(height: 24),
                              _DetailRow(
                                icon: Icons.payments_outlined,
                                label: post.type == PostType.request
                                    ? 'Budget'
                                    : post.type == PostType.job
                                        ? 'Pay'
                                        : 'Price',
                                value:
                                    '${post.pricingType.displayLabel} · ${formatPriceDisplay(post.price)}',
                                valueColor: AppTheme.successGreen,
                              ),
                              if (post.type == PostType.job &&
                                  post.employmentType != null) ...[
                                const Divider(height: 24),
                                _DetailRow(
                                  icon: Icons.work_outline,
                                  label: 'Employment',
                                  value:
                                      post.employmentType!.displayLabel,
                                ),
                              ],
                              const Divider(height: 24),
                              _DetailRow(
                                icon: Icons.trending_up,
                                label: 'Difficulty',
                                value: post.difficultyText,
                                valueColor: post.difficultyColor,
                              ),
                              const Divider(height: 24),
                              _DetailRow(
                                icon: Icons.star_outline,
                                label: 'Rating',
                                value: '${post.rating} / 5.0',
                                valueColor: AppTheme.warningOrange,
                              ),
                            ],
                          ),
                        ),

                        // ── Applicant / provider selection (request owner only) ──
                        if (post.type == PostType.request && isAuthor) ...[
                          const SizedBox(height: 20),
                          _ApplicantsSection(
                            post: post,
                            isDark: isDark,
                            onProviderSelected: () {
                              Navigator.pop(sheetContext);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Row(
                                    children: [
                                      Icon(Icons.check_circle, color: Colors.white, size: 18),
                                      SizedBox(width: 10),
                                      Flexible(child: Text('Provider selected. You can now secure the service.')),
                                    ],
                                  ),
                                  backgroundColor: AppTheme.successGreen,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                              );
                            },
                          ),
                        ],

                        // ── Secure Service button ────────────────────────────
                        // Only on Request posts where the author selected a provider.
                        if (showPayButton) ...[
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isOffline
                                    ? AppTheme.successGreen
                                        .withValues(alpha: 0.55)
                                    : AppTheme.successGreen,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(12)),
                              ),
                              onPressed: () {
                                if (isOffline) {
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(
                                    SnackBar(
                                      content: const Row(
                                        children: [
                                          Icon(Icons.wifi_off_rounded,
                                              color: Colors.white,
                                              size: 18),
                                          SizedBox(width: 10),
                                          Flexible(
                                            child: Text(
                                                "You're offline. Connect to proceed."),
                                          ),
                                        ],
                                      ),
                                      backgroundColor:
                                          AppTheme.warningOrange,
                                      behavior:
                                          SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(
                                                  10)),
                                    ),
                                  );
                                  return;
                                }
                                AuthGuard.requireAuth(
                                  context,
                                  action: 'pay for this service',
                                  onAuthenticated: () {
                                    final buyerUserId = context
                                            .read<AuthProvider>()
                                            .currentUserId ??
                                        '';
                                    final fee = calculatePlatformFee(
                                        post.price);
                                    Navigator.pop(context);
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => PaymentScreen(
                                          postId: post.id,
                                          postTitle: post.title,
                                          amount: post.price,
                                          platformFee: fee,
                                          buyerUserId: buyerUserId,
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                              icon: Icon(
                                isOffline
                                    ? Icons.wifi_off_rounded
                                    : Icons.lock_rounded,
                                size: 18,
                              ),
                              label: Text(
                                isOffline
                                    ? 'Secure Service (offline)'
                                    : 'Secure Service · KES ${(post.price + calculatePlatformFee(post.price)).toStringAsFixed(0)}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                        ],

                        // Contact / action button — hidden for the post author
                        if (!isAuthor) ...[
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.pop(context);
                                AuthGuard.requireAuth(
                                  context,
                                  action: post.type == PostType.request
                                      ? 'apply to this request'
                                      : 'request this service',
                                  onAuthenticated: () =>
                                      _openPrivateChat(context, post),
                                );
                              },
                              icon: Icon(
                                post.type == PostType.offer
                                    ? Icons.handshake_outlined
                                    : Iconsax.send_2,
                              ),
                              label: Text(
                                post.type == PostType.offer
                                    ? 'Request Service'
                                    : 'Apply',
                              ),
                            ),
                          ),
                        ],

                        const SizedBox(height: 24),
                        Text('Comments',
                            style:
                                Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 12),
                        _CommentsList(postId: post.id),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
                // Comment input pinned above keyboard
                Padding(
                  padding: EdgeInsets.only(
                    bottom:
                        MediaQuery.of(sheetContext).viewInsets.bottom,
                    left: 16,
                    right: 16,
                    top: 8,
                  ),
                  child: _CommentInputBar(postId: post.id),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmAndDeletePost(BuildContext sheetContext, BuildContext parentContext, PostModel post) async {
    final confirmed = await showDialog<bool>(
      context: sheetContext,
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
            child: Text('Delete', style: TextStyle(color: AppTheme.errorRed, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (confirmed != true || !parentContext.mounted) return;
    final appProvider = parentContext.read<AppProvider>();
    final currentUserId = parentContext.read<AuthProvider>().currentUserId;
    final success = await appProvider.deletePost(post.id, currentUserId);
    if (!sheetContext.mounted) return;
    Navigator.pop(sheetContext);
    if (!parentContext.mounted) return;
    if (success) {
      await appProvider.loadPosts();
      ScaffoldMessenger.of(parentContext).showSnackBar(
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
    } else {
      ScaffoldMessenger.of(parentContext).showSnackBar(
        SnackBar(
          content: Text(appProvider.error ?? 'Failed to delete post'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.errorRed,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  /// Open private chat with post author. No public application list; messages only in Messages tab.
  Future<void> _openPrivateChat(BuildContext context, PostModel post) async {
    final appProvider = context.read<AppProvider>();
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

    final conv = await appProvider.ensureConversationOnApply(
      applicantId: currentUserId,
      authorId: authorId,
      initialMessage: '',
      postId: post.id,
    );
    if (!context.mounted) return;
    if (conv == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(appProvider.error ?? 'Could not open chat. Please try again.'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.errorRed,
        ),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (c) => ChatScreen(conversation: conv, currentUserId: currentUserId),
      ),
    );
  }

}

/// Applicant list for request post owners — lets them select a provider.
class _ApplicantsSection extends StatefulWidget {
  final PostModel post;
  final bool isDark;
  final VoidCallback onProviderSelected;

  const _ApplicantsSection({
    required this.post,
    required this.isDark,
    required this.onProviderSelected,
  });

  @override
  State<_ApplicantsSection> createState() => _ApplicantsSectionState();
}

class _ApplicantsSectionState extends State<_ApplicantsSection> {
  String? _selecting;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final cardBg = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final selectedId = widget.post.selectedProviderUserId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Applicants', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.primaryAccent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${widget.post.applications.length}',
                style: const TextStyle(
                  color: AppTheme.primaryAccent,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (selectedId != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.successGreen.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.successGreen.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: AppTheme.successGreen, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Provider selected. Tap "Secure Service" to pay.',
                    style: TextStyle(color: textSecondary, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (widget.post.applications.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No applicants yet. Share your request to attract providers.',
              style: TextStyle(color: textSecondary, fontSize: 13),
            ),
          )
        else
          ...widget.post.applications.map((app) {
            final isSelected = app.applicantUserId == selectedId;
            final isSelecting = _selecting == app.applicantUserId;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.successGreen.withValues(alpha: 0.06)
                    : cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.successGreen.withValues(alpha: 0.4)
                      : borderColor,
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: AppTheme.primaryAccent.withValues(alpha: 0.15),
                    backgroundImage: app.applicantAvatarUrl.isNotEmpty
                        ? NetworkImage(app.applicantAvatarUrl)
                        : null,
                    child: app.applicantAvatarUrl.isEmpty
                        ? Text(
                            app.applicantName.isNotEmpty
                                ? app.applicantName[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: AppTheme.primaryAccent,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.applicantName,
                          style: TextStyle(
                            color: textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        if (app.message.isNotEmpty)
                          Text(
                            app.message,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: textSecondary, fontSize: 12),
                          ),
                        if (app.proposedPrice > 0)
                          Text(
                            'Offers KES ${app.proposedPrice.toStringAsFixed(0)}',
                            style: TextStyle(
                              color: AppTheme.successGreen,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (isSelected)
                    const Icon(Icons.check_circle_rounded,
                        color: AppTheme.successGreen, size: 20)
                  else
                    SizedBox(
                      height: 32,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          foregroundColor: AppTheme.primaryAccent,
                          textStyle: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 12),
                        ),
                        onPressed: isSelecting || app.applicantUserId.isEmpty
                            ? null
                            : () async {
                                setState(() => _selecting = app.applicantUserId);
                                try {
                                  await PostService.selectProvider(
                                    widget.post.id,
                                    app.applicantUserId,
                                  );
                                  if (mounted) widget.onProviderSelected();
                                } catch (_) {
                                  if (mounted) {
                                    setState(() => _selecting = null);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Could not select provider. Try again.'),
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  }
                                }
                              },
                        child: isSelecting
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppTheme.primaryAccent),
                              )
                            : const Text('Select'),
                      ),
                    ),
                ],
              ),
            );
          }),
      ],
    );
  }
}

/// Compact badge chip used in the post-detail sheet header badges row.
class _BadgeChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool dot;

  const _BadgeChip({
    required this.label,
    required this.color,
    this.dot = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppTheme.primaryAccent),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: valueColor,
          ),
        ),
      ],
    );
  }
}

/// Comments list only (used inside scroll). Input is in _CommentInputBar for keyboard avoidance.
class _CommentsList extends StatelessWidget {
  final String postId;

  const _CommentsList({required this.postId});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return StreamBuilder<List<PostComment>>(
      stream: CommentServiceFirestore.watchComments(postId),
      builder: (context, snap) {
        final comments = snap.data ?? [];
        if (comments.isEmpty && !snap.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        if (comments.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No comments yet. Be the first!',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
              ),
            ),
          );
        }
        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: comments.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final c = comments[index];
            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkCard : AppTheme.lightBackground,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        c.userName,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _commentTimeAgo(c.timestamp),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(c.text, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            );
          },
        );
      },
    );
  }

  static String _commentTimeAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${t.day}/${t.month}';
  }
}

/// Comment input bar — placed at bottom of sheet with viewInsets so it moves above keyboard.
class _CommentInputBar extends StatefulWidget {
  final String postId;

  const _CommentInputBar({required this.postId});

  @override
  State<_CommentInputBar> createState() => _CommentInputBarState();
}

class _CommentInputBarState extends State<_CommentInputBar> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _addComment() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    final uid = context.read<AuthProvider>().currentUserId ?? '';
    if (uid.isEmpty) return;
    setState(() => _sending = true);
    try {
      await CommentServiceFirestore.addComment(
        postId: widget.postId,
        userId: uid,
        text: text,
      );
      if (mounted) _controller.clear();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to post comment'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final uid = context.read<AuthProvider>().currentUserId ?? '';

    if (uid.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Sign in to comment',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: 'Add a comment...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: isDark ? AppTheme.darkCard : AppTheme.lightBackground,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            maxLines: 2,
            onSubmitted: (_) => _addComment(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          onPressed: _sending ? null : _addComment,
          icon: _sending
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.send_rounded, size: 20),
        ),
      ],
    );
  }
}

// ─── Content-type tab (left-aligned, sized to label) ───────────────────────

class _TabItem extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _TabItem({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = AppTheme.primaryAccent;
    final inactiveColor =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                label,
                style: TextStyle(
                  color: isActive ? activeColor : inactiveColor,
                  fontSize: 15,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              height: 2.5,
              decoration: BoxDecoration(
                color: isActive ? activeColor : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}



