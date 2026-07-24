import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/connectivity_provider.dart';
import '../providers/location_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/loading_empty_offline.dart';
import '../widgets/post_card.dart';
import '../widgets/filter_bottom_sheet.dart';
import '../widgets/auth_guard.dart';
import '../providers/auth_provider.dart';
import 'urgent_requests_screen.dart';
import 'notifications_screen.dart';
import '../models/promotion_models.dart';
import '../services/promotion_service.dart';
import '../utils/feed_composer.dart';
import '../utils/promotion_tracker.dart';
import '../widgets/post_flows.dart';
import 'post_detail_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  // 0 = All, 1 = Requests, 2 = Offers
  int _tabIndex = 0;

  // ── Business Promotion (sponsored slots) ────────────────────────────
  // Fetched NON-BLOCKING in parallel with the organic feed: the feed never
  // waits on promotions and renders organically when the engine is
  // unreachable. Slots are refetched when the feed context changes
  // (refresh / tab / search / filters); search input is debounced.
  SlotsResult _slots = SlotsResult.empty;
  int _slotsRequestSeq = 0;
  Timer? _slotsDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // At cold start the filter is already 'All' and AppProvider's constructor
      // has the feed load in flight — re-triggering setSelectedFilter here
      // issued a SECOND identical fetch of the entire feed. Only reset (and
      // reload) when the filter genuinely differs.
      final appProvider = context.read<AppProvider>();
      if (appProvider.selectedFilter != 'All') {
        appProvider.setSelectedFilter('All');
      }
      // Preload live urgent requests so the header's Urgent pill can show a
      // count — emergency posts must be discoverable without opening anything.
      final location = context.read<LocationProvider>();
      context.read<AppProvider>().loadUrgentPosts(
            userLatitude: location.latitude,
            userLongitude: location.longitude,
          );
      _loadSponsoredSlots();
    });
  }

  @override
  void dispose() {
    _slotsDebounce?.cancel();
    // Flush any queued impressions/clicks before the screen goes away.
    PromotionTracker.instance.flush();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Maps the current feed context to a promotion placement and fetches
  /// slots. Sequence-guarded so a slow older response never overwrites a
  /// newer one.
  Future<void> _loadSponsoredSlots() async {
    final provider = context.read<AppProvider>();
    final location = context.read<LocationProvider>();

    // Sponsored subjects are offer posts — the Requests tab shows none.
    if (_tabIndex == 1) {
      if (mounted && _slots.items.isNotEmpty) {
        setState(() => _slots = SlotsResult.empty);
      }
      return;
    }

    final query = provider.searchQuery.trim();
    final categories = provider.selectedCategories;
    String placement = 'discover';
    String? category;
    String? q;
    if (query.isNotEmpty) {
      placement = 'search';
      q = query;
    } else if (categories.length == 1) {
      placement = 'category';
      category = categories.first;
    }

    final seq = ++_slotsRequestSeq;
    final result = await PromotionService.fetchSlots(
      placement: placement,
      category: category,
      query: q,
      lat: location.latitude,
      lng: location.longitude,
    );
    if (!mounted || seq != _slotsRequestSeq) return;
    PromotionTracker.instance.reset(); // new feed session → fresh impressions
    setState(() => _slots = result);
  }

  /// Debounced slot refetch for per-keystroke search updates.
  void _scheduleSlotReload() {
    _slotsDebounce?.cancel();
    _slotsDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) _loadSponsoredSlots();
    });
  }

  Future<void> _refreshPosts() async {
    _loadSponsoredSlots(); // parallel, non-blocking
    await context.read<AppProvider>().loadPosts();
  }

  void _switchToTab(int tab) {
    if (_tabIndex == tab) return;
    _searchFocus.unfocus();
    _searchController.clear();
    setState(() => _tabIndex = tab);
    final provider = context.read<AppProvider>();
    provider.setSearchQuery('');
    const filters = ['All', 'Requests', 'Offers'];
    provider.setSelectedFilter(filters[tab]);
    _loadSponsoredSlots();
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
          // ── Offline indicator ────────────────────────────────
          // Pinned directly below the status bar, above the Discover/Urgent
          // header — the rest of the page layout is unchanged. Discover is the
          // ONLY screen that carries this persistent strip (users browse a live
          // feed here); it's thin and shows only while offline.
          Consumer<ConnectivityProvider>(
            builder: (_, connectivity, __) => connectivity.isOffline
                ? const OfflineBanner()
                : const SizedBox.shrink(),
          ),

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
                    // The bell is PERMANENT chrome — it must never blink in
                    // and out with auth/connectivity state (offline, session
                    // restore). Only the unread badge and the tap behaviour
                    // depend on who is signed in.
                    Consumer<AuthProvider>(
                      builder: (_, auth, __) {
                        final uid = auth.currentUserId ?? '';
                        final bell = IconButton(
                          icon: const Icon(Icons.notifications_outlined),
                          tooltip: 'Notifications',
                          onPressed: () {
                            if (uid.isEmpty) {
                              AuthGuard.requireAuth(
                                context,
                                action: 'view your notifications',
                                onAuthenticated: () {
                                  final freshUid = context
                                          .read<AuthProvider>()
                                          .currentUserId ??
                                      '';
                                  if (freshUid.isEmpty) return;
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => NotificationsScreen(
                                            userId: freshUid)),
                                  );
                                },
                              );
                              return;
                            }
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      NotificationsScreen(userId: uid)),
                            );
                          },
                        );
                        if (uid.isEmpty) return bell;
                        // Keyed so the badge re-subscribes if the account changes.
                        return NotificationBadge(
                          key: ValueKey('bell_$uid'),
                          userId: uid,
                          child: bell,
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
                  focusNode: _searchFocus,
                  // The focused highlight must never stick: any tap or drag
                  // outside the field (feed scroll, tab tap, card tap)
                  // releases focus immediately.
                  onTapOutside: (_) => _searchFocus.unfocus(),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _searchFocus.unfocus(),
                  onChanged: (value) {
                    provider.setSearchQuery(value);
                    _scheduleSlotReload();
                  },
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
                              _scheduleSlotReload();
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
                        if (mounted) {
                          provider.applyFilters();
                          _loadSponsoredSlots();
                        }
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
          // A load failure is NOT an empty result — show it as a failure with a
          // Retry, so "we couldn't load" is never mistaken for "there's nothing
          // here" (which would wrongly tell the user to change their filters).
          if (provider.error != null) {
            return ErrorRetryView(
              message: provider.error!,
              onRetry: _refreshPosts,
            );
          }
          return EmptyStateView(
            icon: Iconsax.document,
            title: 'No posts found',
            subtitle: 'Try adjusting your filters or search. Pull to refresh.',
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

        // Business Promotion: interleave sponsored offer cards per the
        // server-configured cadence (pure composition — organic order is
        // never changed, sponsored cards never cluster).
        final entries = FeedComposer.compose(
          organic: posts,
          slots: _slots.items,
          config: _slots.serving,
        );

        return RefreshIndicator(
          onRefresh: _refreshPosts,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              final post = entry.post;

              if (entry.sponsored) {
                // Rendered ⇒ visible impression (deduped per feed session).
                PromotionTracker.instance.trackImpression(
                  campaignId: entry.campaignId!,
                  placement: _slots.placement,
                  viewerUserId: context.read<AuthProvider>().currentUserId,
                );
              }

              void trackSponsoredClick() {
                if (!entry.sponsored) return;
                PromotionTracker.instance.trackClick(
                  campaignId: entry.campaignId!,
                  placement: _slots.placement,
                  viewerUserId: context.read<AuthProvider>().currentUserId,
                );
              }

              return PostCard(
                post: post,
                sponsored: entry.sponsored,
                onTap: () {
                  trackSponsoredClick();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PostDetailScreen(post: post),
                    ),
                  );
                },
                onRespond: post.type == PostType.request
                    ? () {
                        AuthGuard.requireAuth(
                          context,
                          action: 'offer service on this request',
                          onAuthenticated: () =>
                              openOfferServiceModal(context, post),
                        );
                      }
                    : () {
                        // Offer post: "Enquire" opens a direct chat with the provider.
                        trackSponsoredClick();
                        if (entry.sponsored) {
                          PromotionTracker.instance.trackAction(
                            campaignId: entry.campaignId!,
                            eventType: 'message',
                            placement: _slots.placement,
                            viewerUserId:
                                context.read<AuthProvider>().currentUserId,
                          );
                        }
                        AuthGuard.requireAuth(
                          context,
                          action: 'enquire about this service',
                          onAuthenticated: () => openPrivateChat(context, post),
                        );
                      },
              );
            },
          ),
        );
      },
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



