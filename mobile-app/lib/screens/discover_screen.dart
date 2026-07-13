import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../utils/phone_utils.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import '../models/attribute_display.dart';
import '../models/post_model.dart';
import '../services/category_schema_service.dart';
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
import '../services/application_service.dart';
import '../services/user_profile_service.dart';
import '../widgets/application_modal.dart';
import 'messages_screen.dart';
import 'urgent_requests_screen.dart';
import 'payment_screen.dart';
import '../services/mpesa_service.dart';
import '../utils/payment_utils.dart';
import '../services/jobs_service.dart';
import 'mark_complete_screen.dart';
import 'approve_or_dispute_screen.dart';
import 'notifications_screen.dart';
import 'applications_screen.dart';

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
      if (!mounted) return;
      context.read<AppProvider>().setSelectedFilter('All');
      // Preload live urgent requests so the header's Urgent pill can show a
      // count — emergency posts must be discoverable without opening anything.
      final location = context.read<LocationProvider>();
      context.read<AppProvider>().loadUrgentPosts(
            userLatitude: location.latitude,
            userLongitude: location.longitude,
          );
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Consumer<AuthProvider>(
                      builder: (_, auth, __) {
                        final uid = auth.currentUserId ?? '';
                        if (uid.isEmpty) return const SizedBox.shrink();
                        return NotificationBadge(
                          userId: uid,
                          child: IconButton(
                            icon: const Icon(Icons.notifications_outlined),
                            tooltip: 'Notifications',
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => NotificationsScreen(userId: uid)),
                            ),
                          ),
                        );
                      },
                    ),
                    // Emergency entry — red ⚡ pill with a live count of active
                    // urgent requests ("Right now" posts within their window).
                    Consumer<AppProvider>(
                      builder: (_, provider, __) {
                        final urgentCount = provider.urgentPosts.length;
                        return GestureDetector(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const UrgentRequestsScreen()),
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: AppTheme.errorRed.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: AppTheme.errorRed.withValues(alpha: 0.4),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.bolt,
                                    size: 16, color: AppTheme.errorRed),
                                const SizedBox(width: 4),
                                const Text(
                                  'Urgent',
                                  style: TextStyle(
                                    color: AppTheme.errorRed,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                                if (urgentCount > 0) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: AppTheme.errorRed,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '$urgentCount',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ],
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
                    _TabPill(
                      label: 'All',
                      isActive: _tabIndex == 0,
                      onTap: () => _switchToTab(0),
                    ),
                    const SizedBox(width: 8),
                    _TabPill(
                      label: 'Requests',
                      isActive: _tabIndex == 1,
                      onTap: () => _switchToTab(1),
                    ),
                    const SizedBox(width: 8),
                    _TabPill(
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
                          action: 'offer service on this request',
                          onAuthenticated: () =>
                              _openOfferServiceModal(context, post),
                        );
                      }
                    : () {
                        // Offer post: "Enquire" opens a direct chat with the provider.
                        AuthGuard.requireAuth(
                          context,
                          action: 'enquire about this service',
                          onAuthenticated: () => _openPrivateChat(context, post),
                        );
                      },
              );
            },
          ),
        );
      },
    );
  }

  void _showPostDetails(BuildContext context, PostModel post) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Local mutable selection state — updated immediately after "Select" to
    // avoid waiting for a full feed reload to show the Secure Service button.
    String? localSelectedId = post.selectedProviderUserId;

    // Local applied state — set true after a background hasApplied() check or
    // after a successful offer submission. Prevents duplicate apply attempts and
    // drives the "Applied" button UI inside this sheet.
    bool localHasApplied = false;
    bool appliedChecked = false; // guard: run the check only once per sheet open
    JobCompletionStatus? jobStatus;
    bool jobStatusChecked = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (_, setSheetState) => Consumer2<AuthProvider, ConnectivityProvider>(
          builder: (_, auth, connectivity, __) {
          final currentUserId = auth.currentUserId ?? '';
          final isAuthor = currentUserId.isNotEmpty &&
              post.authorUserId.isNotEmpty &&
              post.authorUserId == currentUserId;
          final isOffline = connectivity.isOffline;

          // Use localSelectedId so the button appears immediately after selection.
          final showPayButton = post.type == PostType.request &&
              isAuthor &&
              localSelectedId != null &&
              post.price > 0;

          // True when the current user is the provider selected for this request.
          final isSelectedProvider = post.type == PostType.request &&
              currentUserId.isNotEmpty &&
              localSelectedId != null &&
              localSelectedId == currentUserId &&
              !isAuthor;

          // Background hasApplied check — runs once per sheet open.
          // Updates localHasApplied so the button changes to "Applied" state.
          if (!appliedChecked &&
              !isAuthor &&
              currentUserId.isNotEmpty &&
              post.type == PostType.request) {
            appliedChecked = true;
            ApplicationService.hasApplied(post.id, currentUserId).then((applied) {
              if (applied) setSheetState(() => localHasApplied = true);
            });
          }

          // Fetch job lifecycle status once per sheet open for request posts with a selected provider.
          if (!jobStatusChecked &&
              post.type == PostType.request &&
              localSelectedId != null) {
            jobStatusChecked = true;
            JobsService.getJobStatus(post.id).then((s) {
              if (s != null) setSheetState(() => jobStatus = s);
            });
          }

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
                                      if (post.type == PostType.offer && post.authorHasPhone)
                                        _BadgeChip(
                                          label: '✔ Verified Provider',
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

                        // Description (optional for requests since R-1)
                        if (post.description.trim().isNotEmpty) ...[
                          Text('Description',
                              style:
                                  Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 8),
                          Text(post.description,
                              style: Theme.of(context).textTheme.bodyLarge),
                          const SizedBox(height: 24),
                        ],

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
                                // R-4: each intent speaks its own money
                                // language (Budget / Starting price / Salary).
                                label: detailMoneyLabel(post.type),
                                value: detailMoneyValue(
                                  type: post.type,
                                  price: post.price,
                                  pricingType: post.pricingType,
                                ),
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
                              // R-4: the smart-question answers (+ reserved
                              // availability/start/needed signals), labeled
                              // from the schema. The fake Difficulty row is
                              // gone — it was never asked (always "Medium").
                              for (final row in attributeDetailRows(
                                schema: CategorySchemaService.instance
                                    .schemaFor(post.category.name),
                                postType: post.type.name,
                                attributes: post.attributes,
                              )) ...[
                                const Divider(height: 24),
                                _DetailRow(
                                  icon: Icons.check_circle_outline,
                                  label: row.label,
                                  value: row.value,
                                ),
                              ],
                              // Fake "Rating: X / 5.0" row removed (Phase 3.2C):
                              // PostModel.rating was fabricated. Real provider
                              // reputation is shown via ReputationCompact on cards.
                            ],
                          ),
                        ),

                        // ── Applicant / provider selection (request owner only) ──
                        if (post.type == PostType.request && isAuthor) ...[
                          const SizedBox(height: 20),
                          _ApplicantsSection(
                            post: post,
                            isDark: isDark,
                            overrideSelectedId: localSelectedId,
                            onProviderSelected: (String userId) {
                              setSheetState(() => localSelectedId = userId);
                              // Refresh feed in background so re-opened sheets are up to date.
                              context.read<AppProvider>().loadPosts();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Row(
                                    children: [
                                      Icon(Icons.check_circle, color: Colors.white, size: 18),
                                      SizedBox(width: 10),
                                      Flexible(child: Text('Provider selected. Tap "Secure Service" to pay.')),
                                    ],
                                  ),
                                  backgroundColor: AppTheme.successGreen,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                              );
                            },
                            onChatWithApplicant: (String applicantUserId, String applicantName, String applicantAvatarUrl) async {
                              Navigator.pop(sheetContext);
                              await _openChatWithUser(context, post.id, applicantUserId,
                                  otherUserName: applicantName, otherUserAvatar: applicantAvatarUrl);
                            },
                          ),
                        ],

                        // ── Secure Service button ────────────────────────────
                        // Only on Request posts where the author selected a provider.
                        if (showPayButton) ...[
                          const SizedBox(height: 16),
                          _SecureServiceButton(
                            post: post,
                            buyerUserId: currentUserId,
                            providerUserId: localSelectedId,
                            isOffline: isOffline,
                            onTap: (normalizedPhone) {
                              final fee = calculatePlatformFee(post.price);
                              Navigator.pop(sheetContext);
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => PaymentScreen(
                                    postId: post.id,
                                    postTitle: post.title,
                                    amount: post.price,
                                    platformFee: fee,
                                    buyerUserId: currentUserId,
                                    buyerPhone: normalizedPhone,
                                  ),
                                ),
                              );
                            },
                          ),
                        ],

                        // ── Job lifecycle actions ──────────────────────────
                        // Shown on request posts once a provider is selected.
                        if (post.type == PostType.request && localSelectedId != null) ...[
                          // Status card
                          if (jobStatus != null) ...[
                            const SizedBox(height: 16),
                            _JobStatusCard(
                              status: jobStatus!,
                              isDark: isDark,
                              isAuthor: isAuthor,
                              postStatus: post.status,
                            ),
                          ],

                          // Provider: Mark Job Done
                          if (isSelectedProvider && jobStatus == null) ...[
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              height: 52,
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.task_alt_rounded, size: 20),
                                label: const Text('Mark Job Done'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppTheme.successGreen,
                                  side: const BorderSide(color: AppTheme.successGreen),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14)),
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => MarkCompleteScreen(
                                        postId: post.id,
                                        postTitle: post.title,
                                        providerUserId: currentUserId,
                                      ),
                                    ),
                                  ).then((_) {
                                    JobsService.getJobStatus(post.id).then((s) {
                                      if (s != null) setSheetState(() => jobStatus = s);
                                    });
                                  });
                                },
                              ),
                            ),
                          ],

                          // Client: Review Completion
                          if (isAuthor && (jobStatus?.isPendingApproval ?? false)) ...[
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              height: 52,
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.rate_review_rounded, size: 20),
                                label: const Text('Review Completion'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.warningOrange,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14)),
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ApproveOrDisputeScreen(
                                        postId: post.id,
                                        postTitle: post.title,
                                        clientUserId: currentUserId,
                                        providerNote: jobStatus?.providerNote,
                                        amount: post.price,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ],

                        // Contact / action button — hidden for the post author
                        if (!isAuthor) ...[
                          const SizedBox(height: 10),
                          // Show "Applied" badge once duplicate check confirms.
                          if (localHasApplied && post.type == PostType.request)
                            Container(
                              width: double.infinity,
                              height: 52,
                              decoration: BoxDecoration(
                                color: AppTheme.successGreen.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: AppTheme.successGreen.withValues(alpha: 0.45),
                                ),
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.check_circle_rounded,
                                      color: AppTheme.successGreen, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'You already applied to this request',
                                    style: TextStyle(
                                      color: AppTheme.successGreen,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else if (post.type == PostType.request && post.status != 'open')
                            // Request already has a provider / is in progress —
                            // never show "Offer Service" to anyone (Issue 2).
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppTheme.primaryAccent.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                post.status == 'completed'
                                    ? 'This job is completed'
                                    : post.status == 'disputed'
                                        ? 'This job is in dispute'
                                        : 'This request already has a selected provider',
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            )
                          else
                            SizedBox(
                              width: double.infinity,
                              height: 52,
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  Navigator.pop(context);
                                  AuthGuard.requireAuth(
                                    context,
                                    action: post.type == PostType.request
                                        ? 'offer service on this request'
                                        : 'request this service',
                                    onAuthenticated: () => post.type == PostType.request
                                        ? _openOfferServiceModal(context, post)
                                        : _openPrivateChat(context, post),
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
                                      : 'Offer Service',
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
  Future<void> _openOfferServiceModal(BuildContext context, PostModel post) async {
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

  /// Open a chat with an applicant. Passes name/avatar so the header renders
  /// immediately without a DB fetch. The chat row is created on first send.
  Future<void> _openChatWithUser(
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

}

/// Applicant list for request post owners — lets them chat or select a provider.
class _ApplicantsSection extends StatefulWidget {
  final PostModel post;
  final bool isDark;
  final String? overrideSelectedId;
  final Function(String userId) onProviderSelected;
  final Future<void> Function(String applicantUserId, String applicantName, String applicantAvatarUrl) onChatWithApplicant;

  const _ApplicantsSection({
    required this.post,
    required this.isDark,
    required this.onProviderSelected,
    required this.onChatWithApplicant,
    this.overrideSelectedId,
  });

  @override
  State<_ApplicantsSection> createState() => _ApplicantsSectionState();
}

class _ApplicantsSectionState extends State<_ApplicantsSection> {
  String? _selecting;
  bool _chatLoading = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final textTertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    final cardBg = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;

    // Use override (post-selection local state) if available; fallback to DB value.
    final effectiveSelectedId = widget.overrideSelectedId ?? widget.post.selectedProviderUserId;
    final anySelected = effectiveSelectedId != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
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
            const Spacer(),
            // Navigate to dedicated Applications management screen.
            TextButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ApplicationsScreen(
                      postId: widget.post.id,
                      postTitle: widget.post.title,
                      authorUserId: context.read<AuthProvider>().currentUserId ?? '',
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.open_in_full_rounded, size: 13),
              label: const Text('Manage'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Empty state
        if (widget.post.applications.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'No offers yet. Check back later.',
              style: TextStyle(color: textSecondary, fontSize: 13),
            ),
          )
        else
          ...widget.post.applications.map((app) {
            final isSelected = app.applicantUserId == effectiveSelectedId;
            final isSelecting = _selecting == app.applicantUserId;
            final canSelect = !anySelected && !isSelecting && app.applicantUserId.isNotEmpty;

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isSelected ? AppTheme.successGreen.withValues(alpha: 0.06) : cardBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.successGreen.withValues(alpha: 0.45)
                      : borderColor,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top row: avatar + name + timestamp
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      CircleAvatar(
                        radius: 18,
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
                                  fontSize: 14,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          app.applicantName.isNotEmpty ? app.applicantName : 'Anonymous',
                          style: TextStyle(
                            color: textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        formatRelativeTime(app.timestamp),
                        style: TextStyle(color: textTertiary, fontSize: 11.5),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Message
                  Text(
                    app.message.isNotEmpty ? app.message : 'No message provided.',
                    style: TextStyle(
                      color: app.message.isNotEmpty ? textSecondary : textTertiary,
                      fontSize: 12.5,
                      fontStyle: app.message.isEmpty ? FontStyle.italic : FontStyle.normal,
                      height: 1.4,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 10),

                  // Action row
                  if (isSelected)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppTheme.successGreen.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle_rounded, color: AppTheme.successGreen, size: 15),
                          SizedBox(width: 6),
                          Text(
                            'Selected Provider',
                            style: TextStyle(
                              color: AppTheme.successGreen,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        // Chat button
                        SizedBox(
                          height: 34,
                          child: OutlinedButton.icon(
                            onPressed: (_chatLoading || app.applicantUserId.isEmpty)
                                ? null
                                : () async {
                                    setState(() => _chatLoading = true);
                                    try {
                                      await widget.onChatWithApplicant(app.applicantUserId, app.applicantName, app.applicantAvatarUrl);
                                    } finally {
                                      if (mounted) setState(() => _chatLoading = false);
                                    }
                                  },
                            icon: const Icon(Iconsax.message, size: 14),
                            label: const Text('Chat'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Select button
                        SizedBox(
                          height: 34,
                          child: FilledButton(
                            onPressed: canSelect
                                ? () async {
                                    final clientUserId = context.read<AuthProvider>().currentUserId ?? '';
                                    if (clientUserId.isEmpty) return;
                                    setState(() => _selecting = app.applicantUserId);
                                    try {
                                      await JobsService.selectProvider(
                                        postId: widget.post.id,
                                        providerId: app.applicantUserId,
                                        clientUserId: clientUserId,
                                      );
                                      if (mounted) {
                                        setState(() => _selecting = null);
                                        widget.onProviderSelected(app.applicantUserId);
                                      }
                                    } catch (e) {
                                      debugPrint('[SelectProvider] UI caught error: $e');
                                      if (mounted) {
                                        setState(() => _selecting = null);
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: const Row(children: [
                                              Icon(Icons.error_outline, color: Colors.white, size: 18),
                                              SizedBox(width: 10),
                                              Flexible(child: Text('Could not select provider. Try again.')),
                                            ]),
                                            backgroundColor: AppTheme.errorRed,
                                            behavior: SnackBarBehavior.floating,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                          ),
                                        );
                                      }
                                    }
                                  }
                                : null,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                            child: isSelecting
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  )
                                : const Text('Select'),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            );
          }),
      ],
    );
  }
}

/// Displays the current job lifecycle stage inside the post-detail sheet.
class _JobStatusCard extends StatelessWidget {
  final JobCompletionStatus status;
  final bool isDark;
  // Role-aware wording: the CLIENT reviews/approves; the PROVIDER waits on them.
  final bool isAuthor;
  // Canonical post status — lets a resolved dispute (post 'completed') override a
  // stale job_completions='disputed' so this card agrees with the discover card.
  final String postStatus;

  const _JobStatusCard({
    required this.status,
    required this.isDark,
    required this.isAuthor,
    required this.postStatus,
  });

  @override
  Widget build(BuildContext context) {
    final bool resolved = postStatus == 'completed';
    final (label, icon, bg, fg) = switch (status.status) {
      'pending_approval' => (
          isAuthor ? 'Awaiting your review' : 'Awaiting client review',
          Icons.hourglass_top_rounded,
          AppTheme.warningOrange.withValues(alpha: 0.12),
          AppTheme.warningOrange,
        ),
      'approved' => (
          'Job completed — payment released',
          Icons.check_circle_rounded,
          AppTheme.successGreen.withValues(alpha: 0.12),
          AppTheme.successGreen,
        ),
      // A resolved dispute leaves the post 'completed'; don't keep showing
      // "admin reviewing" once the case is closed.
      'disputed' => resolved
          ? (
              'Dispute resolved — job completed',
              Icons.check_circle_rounded,
              AppTheme.successGreen.withValues(alpha: 0.12),
              AppTheme.successGreen,
            )
          : (
              'Dispute opened — admin reviewing',
              Icons.gavel_rounded,
              AppTheme.errorRed.withValues(alpha: 0.10),
              AppTheme.errorRed,
            ),
      _ => (
          'In progress',
          Icons.construction_rounded,
          AppTheme.primaryAccent.withValues(alpha: 0.10),
          AppTheme.primaryAccent,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: fg.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
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

// ─── Secure Service button with payment-status check ────────────────────────

enum _SecureButtonState { loading, ready, paid }

class _SecureServiceButton extends StatefulWidget {
  final PostModel post;
  final String buyerUserId;
  /// Effective selected-provider ID (may be a local override not yet synced to post.selectedProviderUserId).
  final String? providerUserId;
  final bool isOffline;
  /// Called with the normalized 254XXXXXXXXX phone after preflight checks pass.
  final void Function(String normalizedPhone) onTap;

  const _SecureServiceButton({
    required this.post,
    required this.buyerUserId,
    required this.isOffline,
    required this.onTap,
    this.providerUserId,
  });

  @override
  State<_SecureServiceButton> createState() => _SecureServiceButtonState();
}

class _SecureServiceButtonState extends State<_SecureServiceButton> {
  _SecureButtonState _btnState = _SecureButtonState.loading;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _checkPaymentStatus();
  }

  // A transaction in any post-payment state means the service is already secured;
  // "Secure Service" must never reappear once payment has been made (Issue 5).
  static const _securedStatuses = {'paid', 'payout_pending', 'released', 'disputed', 'refunded'};

  Future<void> _checkPaymentStatus() async {
    try {
      final status = await MpesaService.pollPaymentStatus(widget.post.id);
      if (!mounted) return;
      final secured = _securedStatuses.contains(status.status);
      setState(() => _btnState = secured ? _SecureButtonState.paid : _SecureButtonState.ready);
    } catch (_) {
      // 404 = no transaction yet — show the button.
      if (mounted) setState(() => _btnState = _SecureButtonState.ready);
    }
  }

  Future<void> _handleTap() async {
    if (widget.isOffline) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(children: [
            Icon(Icons.wifi_off_rounded, color: Colors.white, size: 18),
            SizedBox(width: 10),
            Flexible(child: Text("You're offline. Connect to proceed.")),
          ]),
          backgroundColor: AppTheme.warningOrange,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    if (widget.buyerUserId.isEmpty) return;

    setState(() => _checking = true);
    try {
      // ── Precheck 1: buyer M-Pesa phone ───────────────────────────────────
      String? rawPhone = await UserProfileService.getMpesaPhone(widget.buyerUserId);
      if (!mounted) return;

      // Fallback: for phone-auth users the Firebase phone number is the same
      // M-Pesa number — use it when the Supabase profile hasn't been explicitly set.
      if ((rawPhone == null || rawPhone.isEmpty)) {
        final fbPhone = context.read<AuthProvider>().currentUser?.phoneNumber;
        if (fbPhone != null && fbPhone.isNotEmpty) {
          debugPrint('[SecureBtn] DB phone missing — falling back to Firebase phone');
          rawPhone = fbPhone;
        }
      }

      debugPrint('[SecureBtn] buyer raw="$rawPhone"');
      final normalizedPhone = rawPhone != null ? normalizeKenyanNumber(rawPhone) : null;
      debugPrint('[SecureBtn] buyer normalized="$normalizedPhone"');

      if (normalizedPhone == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(children: [
              Icon(Icons.phone_android_rounded, color: Colors.white, size: 18),
              SizedBox(width: 10),
              Flexible(child: Text('Add a valid M-Pesa number in Profile → Payment Settings.')),
            ]),
            backgroundColor: AppTheme.warningOrange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            duration: const Duration(seconds: 4),
          ),
        );
        return;
      }

      // ── Precheck 2: selected provider still has an M-Pesa number ─────────
      final providerUserId =
          widget.providerUserId ?? widget.post.selectedProviderUserId;
      if (providerUserId != null && providerUserId.isNotEmpty) {
        final providerRaw = await UserProfileService.getMpesaPhone(providerUserId);
        if (!mounted) return;
        if (providerRaw == null || providerRaw.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Row(children: [
                Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
                SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'The selected provider has not added their M-Pesa number yet. '
                    'Ask them to add it before you can pay.',
                  ),
                ),
              ]),
              backgroundColor: AppTheme.warningOrange,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              duration: const Duration(seconds: 5),
            ),
          );
          return;
        }
      }

      // ── Precheck 3: post is not already paid ─────────────────────────────
      // (pollPaymentStatus was already checked in initState; re-verify on tap
      //  in case the user tapped "Secure Service" twice or state is stale.)
      if (_btnState == _SecureButtonState.paid) return;

      // All checks passed — proceed to payment.
      widget.onTap(normalizedPhone);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_btnState == _SecureButtonState.loading) {
      return const SizedBox(
        height: 52,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.successGreen),
          ),
        ),
      );
    }

    if (_btnState == _SecureButtonState.paid) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppTheme.successGreen.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.successGreen.withValues(alpha: 0.4)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_rounded, color: AppTheme.successGreen, size: 18),
            SizedBox(width: 8),
            Text(
              'Payment Secured',
              style: TextStyle(
                color: AppTheme.successGreen,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ],
        ),
      );
    }

    final total = formatPriceWithCommas(widget.post.price + calculatePlatformFee(widget.post.price));
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: widget.isOffline
              ? AppTheme.successGreen.withValues(alpha: 0.55)
              : AppTheme.successGreen,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: _checking ? null : _handleTap,
        icon: _checking
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : Icon(widget.isOffline ? Icons.wifi_off_rounded : Icons.lock_rounded, size: 18),
        label: Text(
          widget.isOffline ? 'Secure Service (offline)' : 'Secure Service · KES $total',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

// ─── Pill/capsule tab button ────────────────────────────────────────────────

class _TabPill extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _TabPill({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeBg = AppTheme.primaryAccent;
    final inactiveBg = isDark
        ? const Color(0xFF2C2C2E)
        : const Color(0xFFE5E5EA);
    final activeText = Colors.white;
    final inactiveText =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: isActive ? activeBg : inactiveBg,
          borderRadius: BorderRadius.circular(999),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: AppTheme.primaryAccent.withValues(alpha: 0.30),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          style: TextStyle(
            color: isActive ? activeText : inactiveText,
            fontSize: 14,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
          ),
          child: Text(label),
        ),
      ),
    );
  }
}



