import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/connectivity_provider.dart';
import '../providers/location_provider.dart';
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
import '../config/supabase_config.dart';
import 'messages_screen.dart';
import 'urgent_requests_screen.dart';
import 'payment_screen.dart';
import 'provider_registration_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final TextEditingController _searchController = TextEditingController();

  // Feed mode
  bool _isProvidersTab = false;

  // Provider feed state
  String _providerFilter = 'All';
  List<Map<String, dynamic>> _providers = [];
  List<Map<String, dynamic>> _filteredProviders = [];
  bool _isLoadingProviders = false;
  String? _providersError;
  String _providerSearchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refreshPosts() async {
    await context.read<AppProvider>().loadPosts();
  }

  Future<void> _fetchProviders() async {
    if (!mounted) return;
    setState(() {
      _isLoadingProviders = true;
      _providersError = null;
    });
    try {
      final data = await SupabaseConfig.client
          .from('providers')
          .select('id, name, services, location, created_at')
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _providers = List<Map<String, dynamic>>.from(data as List);
        _isLoadingProviders = false;
      });
      _applyProviderFilters();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _providersError = 'Could not load providers. Pull to refresh.';
        _isLoadingProviders = false;
      });
    }
  }

  void _applyProviderFilters() {
    final query = _providerSearchQuery.toLowerCase();
    var result = List<Map<String, dynamic>>.from(_providers);

    if (query.isNotEmpty) {
      result = result.where((p) {
        final name = (p['name'] as String? ?? '').toLowerCase();
        final location = (p['location'] as String? ?? '').toLowerCase();
        final rawServices = p['services'];
        final servicesStr = rawServices is List
            ? rawServices.join(' ').toLowerCase()
            : (rawServices?.toString().toLowerCase() ?? '');
        return name.contains(query) ||
            servicesStr.contains(query) ||
            location.contains(query);
      }).toList();
    }

    if (_providerFilter == 'Nearby') {
      final city =
          context.read<LocationProvider>().city?.toLowerCase() ?? '';
      if (city.isNotEmpty) {
        result = result
            .where((p) => (p['location'] as String? ?? '')
                .toLowerCase()
                .contains(city))
            .toList();
      }
    }
    // 'Top Rated' and 'All' keep existing order (newest-first from Supabase)

    if (mounted) setState(() => _filteredProviders = result);
  }

  void _switchToTab(bool toProviders) {
    if (_isProvidersTab == toProviders) return;
    _searchController.clear();
    setState(() {
      _isProvidersTab = toProviders;
      _providerFilter = 'All';
      _providerSearchQuery = '';
    });
    if (toProviders) {
      if (_providers.isEmpty) _fetchProviders();
    } else {
      context.read<AppProvider>().setSearchQuery('');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final searchText = _searchController.text;

    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Top bar ──────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
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
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Consumer<AppProvider>(
              builder: (context, provider, _) {
                return TextField(
                  controller: _searchController,
                  onChanged: (value) {
                    if (_isProvidersTab) {
                      setState(() => _providerSearchQuery = value);
                      _applyProviderFilters();
                    } else {
                      provider.setSearchQuery(value);
                    }
                  },
                  decoration: InputDecoration(
                    hintText: _isProvidersTab
                        ? 'Search service providers...'
                        : 'Search services, tasks, or offers...',
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
                              if (_isProvidersTab) {
                                setState(() => _providerSearchQuery = '');
                                _applyProviderFilters();
                              } else {
                                provider.setSearchQuery('');
                              }
                            },
                          )
                        : null,
                  ),
                );
              },
            ),
          ),

          // ── Content-type toggle (Posts | Providers) ──────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Row(
              children: [
                _ToggleTab(
                  label: 'Posts',
                  isActive: !_isProvidersTab,
                  onTap: () => _switchToTab(false),
                ),
                const SizedBox(width: 28),
                _ToggleTab(
                  label: 'Providers',
                  isActive: _isProvidersTab,
                  onTap: () => _switchToTab(true),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // ── Dynamic filter row ───────────────────────────────
          _buildFilterRow(isDark),

          // ── Context label (only when user has typed something) ─
          if (searchText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Text(
                _isProvidersTab
                    ? 'Showing service providers for "$searchText"'
                    : 'Showing posts for "$searchText"',
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
            child: _isProvidersTab
                ? _buildProvidersFeed(isDark)
                : _buildPostsFeed(),
          ),
        ],
      ),
    );
  }

  // ── Filter rows ────────────────────────────────────────────────

  Widget _buildFilterRow(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: _isProvidersTab
          ? _buildProviderFilterRow(isDark)
          : _buildPostFilterRow(isDark),
    );
  }

  Widget _buildPostFilterRow(bool isDark) {
    return Consumer<AppProvider>(
      builder: (context, provider, _) {
        return Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: ['All', 'Need Help', 'Can Help'].map((filter) {
                    final isSelected = provider.selectedFilter == filter;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () => provider.setSelectedFilter(filter),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 10),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppTheme.primaryAccent
                                : (isDark
                                    ? AppTheme.darkCard
                                    : AppTheme.lightCard),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: isSelected
                                  ? AppTheme.primaryAccent
                                  : (isDark
                                      ? AppTheme.darkBorder
                                      : AppTheme.lightBorder),
                            ),
                          ),
                          child: Text(
                            filter,
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : (isDark
                                      ? AppTheme.darkTextPrimary
                                      : AppTheme.lightTextPrimary),
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
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: provider.hasActiveFilters
                      ? AppTheme.primaryAccent.withValues(alpha: 0.12)
                      : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
                  borderRadius: BorderRadius.circular(14),
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
    );
  }

  Widget _buildProviderFilterRow(bool isDark) {
    const filters = ['All', 'Nearby', 'Top Rated'];
    return Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: filters.map((filter) {
                final isSelected = _providerFilter == filter;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _providerFilter = filter);
                      _applyProviderFilters();
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppTheme.primaryAccent
                            : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: isSelected
                              ? AppTheme.primaryAccent
                              : (isDark
                                  ? AppTheme.darkBorder
                                  : AppTheme.lightBorder),
                        ),
                      ),
                      child: Text(
                        filter,
                        style: TextStyle(
                          color: isSelected
                              ? Colors.white
                              : (isDark
                                  ? AppTheme.darkTextPrimary
                                  : AppTheme.lightTextPrimary),
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
        // Filter icon (reserved for future provider filters)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
          ),
          child: Icon(
            Iconsax.filter,
            size: 18,
            color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
          ),
        ),
      ],
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

  Widget _buildProvidersFeed(bool isDark) {
    if (_isLoadingProviders && _filteredProviders.isEmpty) {
      return const FeedSkeletonList();
    }

    if (_filteredProviders.isEmpty && !_isLoadingProviders) {
      return EmptyStateView(
        icon: Iconsax.profile_2user,
        title: _providersError != null
            ? 'Could not load providers'
            : 'No providers found',
        subtitle: _providersError ??
            (_providerFilter == 'Nearby'
                ? 'No providers near you yet. Try "All" to see everyone.'
                : 'No service providers registered yet. Be the first!'),
        actions: [
          TextButton.icon(
            onPressed: _fetchProviders,
            icon: const Icon(Icons.refresh, size: 20),
            label: const Text('Refresh'),
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchProviders,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: _filteredProviders.length,
        itemBuilder: (context, index) {
          return _ProviderCard(
            provider: _filteredProviders[index],
            isDark: isDark,
          );
        },
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
                                      color: post.typeBadgeColor.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      post.typeDisplayLabel,
                                      style: TextStyle(
                                        color: post.typeBadgeColor,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
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
                            label: post.type == PostType.request
                                ? 'Budget'
                                : post.type == PostType.job
                                    ? 'Pay'
                                    : 'Price',
                            value: '${post.pricingType.displayLabel} · ${formatPriceDisplay(post.price)}',
                            valueColor: AppTheme.successGreen,
                          ),
                          if (post.type == PostType.job && post.employmentType != null) ...[
                            const Divider(height: 24),
                            _DetailRow(
                              icon: Icons.work_outline,
                              label: 'Employment',
                              value: post.employmentType!.displayLabel,
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

                    // Public comments list (input is fixed below with keyboard avoidance)
                    const SizedBox(height: 24),
                    Text(
                      'Comments',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    _CommentsList(postId: post.id),
                    const SizedBox(height: 24),

                    // Contact = private DM only (no public responders)
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          AuthGuard.requireAuth(
                            context,
                            action: post.type == PostType.request
                                ? 'message about this help request'
                                : 'contact this provider',
                            onAuthenticated: () => _openPrivateChat(context, post),
                          );
                        },
                        icon: Icon(
                          post.type == PostType.request ? Iconsax.send_2 : Iconsax.message,
                        ),
                        label: Text(
                          post.type == PostType.request ? 'I Can Help' : 'Contact Provider',
                        ),
                      ),
                    ),

                    // Pay button — offer posts only, non-author viewers
                    if (post.type == PostType.offer && !isAuthor && post.price > 0) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.successGreen,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () {
                            AuthGuard.requireAuth(
                              context,
                              action: 'pay for this service',
                              onAuthenticated: () {
                                final buyerUserId =
                                    context.read<AuthProvider>().currentUserId ?? '';
                                Navigator.pop(context);
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => PaymentScreen(
                                      postId: post.id,
                                      postTitle: post.title,
                                      amount: post.price,
                                      buyerUserId: buyerUserId,
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                          icon: const Icon(Icons.payment),
                          label: const Text('Secure & Pay',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Comment input fixed above keyboard — padding keeps it visible when keyboard opens
            Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
                left: 16,
                right: 16,
                top: 8,
              ),
              child: _CommentInputBar(postId: post.id),
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

// ─── Content-type toggle tab ────────────────────────────────────────────────

/// A single tab in the Posts / Providers toggle row.
/// Shows label text; active tab has a coloured underline bar.
class _ToggleTab extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _ToggleTab({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeColor =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final inactiveColor =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isActive ? activeColor : inactiveColor,
              fontSize: 16,
              fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          const SizedBox(height: 5),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            height: 2.5,
            width: isActive ? label.length * 9.8 : 0,
            decoration: BoxDecoration(
              color: AppTheme.primaryAccent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Provider card ──────────────────────────────────────────────────────────

/// Card shown in the Providers feed.
class _ProviderCard extends StatelessWidget {
  final Map<String, dynamic> provider;
  final bool isDark;

  const _ProviderCard({required this.provider, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final name = provider['name'] as String? ?? 'Unknown';
    final location = provider['location'] as String? ?? '';
    final rawServices = provider['services'];
    final List<String> services = rawServices is List
        ? rawServices.map((s) => s.toString()).toList()
        : (rawServices?.toString().isNotEmpty == true
            ? [rawServices.toString()]
            : []);

    // Build initials (up to 2 words)
    final initials = name.trim().split(RegExp(r'\s+')).take(2).map((w) {
      return w.isEmpty ? '' : w[0].toUpperCase();
    }).join();

    final cardBg = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final textPrimary =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar with gradient initials
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppTheme.primaryAccent, AppTheme.secondaryAccent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: Text(
                initials.isEmpty ? '?' : initials,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),

          // Name, location, service tags
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (location.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.location_on_outlined,
                          size: 13, color: textSecondary),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          location,
                          style:
                              TextStyle(color: textSecondary, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                if (services.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: services.take(4).map((service) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryAccent.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppTheme.primaryAccent
                                  .withValues(alpha: 0.25)),
                        ),
                        child: Text(
                          service,
                          style: const TextStyle(
                            color: AppTheme.primaryAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),

          // Verified badge
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppTheme.successGreen.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.verified_rounded,
                size: 16, color: AppTheme.successGreen),
          ),
        ],
      ),
    );
  }
}

// ─── Legacy banner (kept, no longer rendered in main build) ─────────────────

/// Collapsible provider intro banner shown at the top of the feed.
class _ProviderIntroBanner extends StatefulWidget {
  @override
  State<_ProviderIntroBanner> createState() => _ProviderIntroBannerState();
}

class _ProviderIntroBannerState extends State<_ProviderIntroBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor),
          gradient: LinearGradient(
            colors: [
              AppTheme.primaryAccent.withValues(alpha: 0.08),
              AppTheme.secondaryAccent.withValues(alpha: 0.04),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.primaryAccent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.verified_user_outlined,
                  color: AppTheme.primaryAccent, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Offer your services here',
                      style: TextStyle(
                          color: textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13)),
                  const SizedBox(height: 2),
                  Text('Become a provider & get paid via M-Pesa',
                      style: TextStyle(color: textSecondary, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ProviderRegistrationScreen(),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.primaryAccent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Join',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 12)),
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => setState(() => _dismissed = true),
              child: Icon(Icons.close, size: 16, color: textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
