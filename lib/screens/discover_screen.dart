import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/post_card.dart';
import '../widgets/filter_bottom_sheet.dart';
import '../widgets/application_modal.dart';
import '../widgets/auth_guard.dart';
import '../widgets/marketplace_card_components.dart';
import '../providers/auth_provider.dart';
import 'messages_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refreshPosts() async {
    await context.read<AppProvider>().loadPosts();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      child: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Consumer<AppProvider>(
              builder: (context, provider, _) {
                return TextField(
                  controller: _searchController,
                  onChanged: provider.setSearchQuery,
                  decoration: InputDecoration(
                    hintText: 'Search services, tasks, or offers...',
                    prefixIcon: Icon(
                      Iconsax.search_normal,
                      color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                    ),
                    suffixIcon: provider.searchQuery.isNotEmpty
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

          // Filter Row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Consumer<AppProvider>(
              builder: (context, provider, _) {
                return Row(
                  children: [
                    // Filter Pills
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: ['All', 'Requests', 'Offers'].map((filter) {
                            final isSelected = provider.selectedFilter == filter;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: GestureDetector(
                                onTap: () => provider.setSelectedFilter(filter),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? AppTheme.primaryAccent
                                        : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(
                                      color: isSelected
                                          ? AppTheme.primaryAccent
                                          : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
                                    ),
                                  ),
                                  child: Text(
                                    filter,
                                    style: TextStyle(
                                      color: isSelected
                                          ? Colors.white
                                          : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Filter Button
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
                            builder: (context, scrollController) {
                              return const FilterBottomSheet();
                            },
                          ),
                        );
                        // Reload posts after filter changes
                        if (mounted) {
                          provider.applyFilters();
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: provider.hasActiveFilters 
                              ? AppTheme.primaryAccent.withValues(alpha: 0.12)
                              : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: provider.hasActiveFilters
                                ? AppTheme.primaryAccent
                                : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
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
                                  : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
                            ),
                            if (provider.hasActiveFilters) ...[
                              const SizedBox(width: 6),
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
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

          const SizedBox(height: 16),

          // Posts List
          Expanded(
            child: Consumer<AppProvider>(
              builder: (context, provider, _) {
                if (provider.isLoadingPosts) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppTheme.primaryAccent,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Loading...',
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                final posts = provider.filteredPosts;

                if (posts.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Icon(
                            Iconsax.document,
                            size: 36,
                            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'No posts found',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          provider.error ?? 'Try adjusting your filters or search',
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton.icon(
                              onPressed: _refreshPosts,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Refresh'),
                            ),
                            if (provider.hasActiveFilters) ...[
                              const SizedBox(width: 12),
                              TextButton.icon(
                                onPressed: () => provider.clearFilters(),
                                icon: const Icon(Iconsax.close_circle),
                                label: const Text('Clear Filters'),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
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
                            ? () => _openRespondModal(context, post)
                            : null,
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showPostDetails(BuildContext context, PostModel post) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final currentUserId = context.read<AuthProvider>().currentUserId ?? '';
    final isAuthor = currentUserId.isNotEmpty && post.authorUserId == currentUserId;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        height: MediaQuery.of(sheetContext).size.height * 0.85,
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: Icon(Icons.close, color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
                    onPressed: () => Navigator.pop(sheetContext),
                  ),
                  if (isAuthor)
                    TextButton.icon(
                      onPressed: () => _confirmAndDeletePost(sheetContext, context, post),
                      icon: Icon(Icons.delete_outline, size: 20, color: AppTheme.errorRed),
                      label: Text('Delete', style: TextStyle(color: AppTheme.errorRed, fontWeight: FontWeight.w600)),
                    )
                  else
                    const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
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
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    color: AppTheme.darkCard,
                                    child: const Icon(Icons.image_not_supported),
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
                            color: AppTheme.primaryAccent.withValues(alpha: 0.12),
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
                                style: Theme.of(context).textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: AppTheme.primaryAccent.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      post.category.name,
                                      style: TextStyle(
                                        color: AppTheme.primaryAccent,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: post.urgencyColor.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 6,
                                          height: 6,
                                          decoration: BoxDecoration(
                                            color: post.urgencyColor,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          post.urgencyText,
                                          style: TextStyle(
                                            color: post.urgencyColor,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
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
                    Text(
                      'Description',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      post.description,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 24),

                    // Details Grid
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isDark ? AppTheme.darkCard : AppTheme.lightBackground,
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
                            label: 'Budget',
                            value: 'KES ${_formatPrice(post.price)}',
                            valueColor: AppTheme.successGreen,
                          ),
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

                    // Applications section
                    if (post.applications.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Text(
                        'Responses (${post.applications.length})',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      ...post.applications.map((app) {
                        final currentUserId = context.read<AuthProvider>().currentUserId ?? '';
                        final isAuthor = currentUserId.isNotEmpty && currentUserId == post.authorUserId;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  MarketplaceAvatar(
                                    imageUrl: app.applicantAvatarUrl.isNotEmpty ? app.applicantAvatarUrl : null,
                                    displayName: app.applicantName,
                                    size: 36,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          app.applicantName,
                                          style: Theme.of(context).textTheme.titleMedium,
                                        ),
                                        Text(
                                          'KES ${_formatPrice(app.proposedPrice)}',
                                          style: TextStyle(
                                            color: AppTheme.successGreen,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isAuthor)
                                    TextButton(
                                      onPressed: () => _acceptApplicationAndChat(context, post, app),
                                      child: const Text('Accept'),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                app.message,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        );
                      }),
                    ],

                    const SizedBox(height: 32),
                    
                    // Action Button
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          // Require auth before applying
                          AuthGuard.requireAuth(
                            context,
                            action: post.type == PostType.request 
                                ? 'respond to this request' 
                                : 'contact this provider',
                            onAuthenticated: () {
                              _showApplicationModal(context, post);
                            },
                          );
                        },
                        icon: Icon(
                          post.type == PostType.request 
                              ? Iconsax.send_2 
                              : Iconsax.message,
                        ),
                        label: Text(
                          post.type == PostType.request 
                              ? 'Respond to Request' 
                              : 'Contact Provider',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
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

  void _openRespondModal(BuildContext context, PostModel post) {
    AuthGuard.requireAuth(
      context,
      action: 'respond to this request',
      onAuthenticated: () => _showApplicationModal(context, post),
    );
  }

  Future<void> _acceptApplicationAndChat(BuildContext context, PostModel post, Application app) async {
    final appProvider = context.read<AppProvider>();
    final currentUserId = context.read<AuthProvider>().currentUserId ?? '';
    final otherUserId = app.applicantUserId.isNotEmpty ? app.applicantUserId : app.applicantTempId;
    if (otherUserId.isEmpty) return;
    final conv = await appProvider.createConversationOnAccept(
      currentUserId: currentUserId,
      otherUserId: otherUserId,
      otherUserName: app.applicantName,
    );
    if (!context.mounted || conv == null) return;
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (c) => ChatScreen(conversation: conv, currentUserId: currentUserId),
      ),
    );
  }

  void _showApplicationModal(BuildContext context, PostModel post) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(modalContext).viewInsets.bottom,
        ),
        child: ApplicationModal(
          title: post.title,
          type: post.type == PostType.request ? 'request' : 'offer',
          suggestedPrice: post.price,
          onSubmit: (message, proposedPrice) async {
            final provider = context.read<AppProvider>();
            
            // Submit to Supabase
            final currentUserId = context.read<AuthProvider>().currentUserId;
            final success = await provider.submitApplicationToPost(
              post.id,
              currentUserId: currentUserId,
              message: message,
              proposedPrice: proposedPrice,
            );

            if (context.mounted) {
              if (success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.white),
                        const SizedBox(width: 12),
                        const Text('Application submitted!'),
                      ],
                    ),
                    behavior: SnackBarBehavior.floating,
                    backgroundColor: AppTheme.successGreen,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Row(
                      children: [
                        const Icon(Icons.error_outline, color: Colors.white),
                        const SizedBox(width: 12),
                        Text(provider.error ?? 'Failed to submit application'),
                      ],
                    ),
                    behavior: SnackBarBehavior.floating,
                    backgroundColor: AppTheme.errorRed,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                );
              }
            }
          },
        ),
      ),
    );
  }

  String _formatPrice(double price) {
    if (price >= 1000000) {
      return '${(price / 1000000).toStringAsFixed(1)}M';
    } else if (price >= 1000) {
      return '${(price / 1000).toStringAsFixed(price % 1000 == 0 ? 0 : 1)}K';
    }
    return price.toStringAsFixed(0);
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
