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
import '../widgets/filter_pill.dart';
import '../widgets/auth_guard.dart';
import '../providers/auth_provider.dart';
import 'urgent_requests_screen.dart';
import 'notifications_screen.dart';
import '../models/promotion_models.dart';
import '../services/feed_snapshot.dart';
import '../services/interaction_tracker.dart';
import '../services/promotion_service.dart';
import '../utils/feed_composer.dart';
import '../utils/post_ownership.dart';
import '../utils/promotion_tracker.dart';
import '../utils/urgent_window.dart';
import '../widgets/post_flows.dart';

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

  /// Owned here so applying a waiting ranking can also return the reader to the
  /// top — installing a new order while someone is 30 cards down would leave
  /// them somewhere arbitrary in a list they did not ask to have rearranged.
  final ScrollController _feedScroll = ScrollController();

  /// Past the first card. Below this the reader is still at the top of the feed
  /// and a swap costs them nothing; above it, they are reading, and a ranking
  /// that lands unannounced moves what is under their thumb.
  static const double _engagedOffset = 160;

  @override
  void initState() {
    super.initState();
    _feedScroll.addListener(_reportEngagement);
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

  /// Tell the provider whether someone is reading, so a rebuild that finishes
  /// mid-scroll is OFFERED rather than applied. Cheap enough to run on every
  /// scroll notification: the provider ignores anything that is not a change.
  void _reportEngagement() {
    if (!mounted || !_feedScroll.hasClients) return;
    context
        .read<AppProvider>()
        .setFeedEngaged(_feedScroll.offset > _engagedOffset);
  }

  @override
  void dispose() {
    _feedScroll.removeListener(_reportEngagement);
    _slotsDebounce?.cancel();
    // Flush any queued impressions/clicks before the screen goes away.
    PromotionTracker.instance.flush();
    // Same for organic behavioural events (ranking signals 9 and 10).
    InteractionTracker.instance.flush();
    _searchController.dispose();
    _searchFocus.dispose();
    _feedScroll.dispose();
    super.dispose();
  }

  /// Show the ranking that has been waiting, and put the reader back at the top
  /// of it. This is the ONLY path by which a background rebuild reaches the
  /// screen while Discover is in front of the user — and it runs because they
  /// tapped it.
  void _applyPendingFeed() {
    context.read<AppProvider>().applyPendingFeed();
    if (_feedScroll.hasClients) {
      _feedScroll.animateTo(
        0,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
    _loadSponsoredSlots();
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
                        // Counts only requests whose window is still open. The
                        // list is loaded once and held, so without this the
                        // badge kept counting emergencies that had already
                        // expired — and every caller now loads the same page
                        // size, so this is a count rather than a page length.
                        final urgentCount =
                            openUrgentPosts(provider.urgentPosts, DateTime.now())
                                .length;
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
                  onSubmitted: (value) {
                    _searchFocus.unfocus();
                    // A COMMITTED search: reloads immediately (no debounce) and
                    // is the only form recorded as a behavioural signal.
                    // Prefixes typed on the way here are not searches.
                    provider.setSearchQuery(value, submitted: true);
                    _scheduleSlotReload();
                  },
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
                    FilterPill(
                      label: 'All',
                      isActive: _tabIndex == 0,
                      onTap: () => _switchToTab(0),
                    ),
                    const SizedBox(width: FilterPill.gap),
                    FilterPill(
                      label: 'Requests',
                      isActive: _tabIndex == 1,
                      onTap: () => _switchToTab(1),
                    ),
                    const SizedBox(width: FilterPill.gap),
                    FilterPill(
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
          //
          // The prompt floats OVER the list rather than sitting above it: it
          // must not push the feed down when it appears, because moving the
          // cards is the exact thing this whole mechanism exists to avoid.
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _buildPostsFeed()),
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(child: _buildNewRecommendationsPill()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// "New recommendations available" — the offer.
  ///
  /// A better ranking has been computed while the user was reading. It is NOT
  /// applied: the reader decides when the feed rearranges. This is the standard
  /// production behaviour for a live-ranked feed, and the reason Discover can be
  /// both fresh and calm at the same time.
  Widget _buildNewRecommendationsPill() {
    return Consumer<AppProvider>(
      builder: (context, provider, _) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final newPosts = provider.pendingFeedNewPostCount;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SizeTransition(sizeFactor: animation, child: child),
          ),
          child: !provider.hasPendingFeed
              ? const SizedBox.shrink()
              : Semantics(
                  button: true,
                  label: 'Show new recommendations',
                  child: Material(
                    color: AppTheme.primaryAccent,
                    borderRadius: BorderRadius.circular(24),
                    elevation: 4,
                    shadowColor: Colors.black.withValues(alpha: isDark ? 0.5 : 0.25),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: _applyPendingFeed,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 9),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.arrow_upward_rounded,
                                size: 16, color: Colors.white),
                            const SizedBox(width: 7),
                            Text(
                              // Says something true, or says nothing specific.
                              // "3 new posts" when three arrived; the generic
                              // line when the change is a re-ranking rather
                              // than new listings.
                              newPosts > 0
                                  ? '$newPosts new ${newPosts == 1 ? 'post' : 'posts'}'
                                  : 'New recommendations',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }

  // ── Feed widgets ────────────────────────────────────────────────

  /// Discover's four states, and nothing else.
  ///
  /// WHAT THIS REPLACED
  /// ------------------
  /// The old version branched on `isLoadingPosts && posts.isEmpty` → skeletons,
  /// then `posts.isEmpty` → "No posts found". Between those two lines sat a
  /// state neither of them described: the app has started, no request is in
  /// flight yet (the first ranking waits for the viewer identity to resolve),
  /// and the list is empty because nothing has been asked for. That state fell
  /// through to the empty view — so the first thing every user saw on opening
  /// Help24 was the marketplace declaring itself empty, followed by skeletons,
  /// followed by the feed.
  ///
  /// [AppProvider.feedPresentation] now names the state explicitly and defaults
  /// to loading, so the empty view is reachable only from a completed load for
  /// the question currently being asked. Every transition between the four is a
  /// crossfade; the feed is never cleared to reach one.
  Widget _buildPostsFeed() {
    return Consumer2<AppProvider, ConnectivityProvider>(
      builder: (context, provider, connectivity, _) {
        final presentation = provider.feedPresentation;

        // Offline outranks the rest ONLY when there is nothing to render. With
        // posts on screen — cached or live — the thin banner at the top of the
        // screen is the whole story, and the feed stays readable.
        if (presentation != FeedPresentation.content && connectivity.isOffline) {
          return _crossfade(OfflineEmptyView(
            key: const ValueKey('feed-offline'),
            message: 'No internet connection',
            onRetry: () {
              connectivity.checkNow();
              _refreshPosts();
            },
          ));
        }

        return _crossfade(switch (presentation) {
          // Shimmer is the loading UI, shown from the first frame — there is no
          // intermediate text, blank page or empty state ahead of it.
          FeedPresentation.loading =>
            const FeedSkeletonList(key: ValueKey('feed-loading')),

          // A load failure is NOT an empty result — it gets a Retry, so "we
          // couldn't load" is never mistaken for "there's nothing here" (which
          // would wrongly tell the user to change their filters).
          FeedPresentation.failed => ErrorRetryView(
              key: const ValueKey('feed-failed'),
              message: provider.discoverError ?? 'Something went wrong.',
              onRetry: _refreshPosts,
            ),

          // Terminal. Reached only once the request completed, the ranking
          // engine (or its fallback) answered, the filters were applied and the
          // result really was zero rows for this exact question.
          FeedPresentation.empty => EmptyStateView(
              key: const ValueKey('feed-empty'),
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
            ),

          // Keyed by the snapshot generation so REPLACING a ranking crossfades,
          // while editing the posts within one (an optimistic insert, an
          // "Applied" badge) rebuilds the existing list in place and keeps the
          // reader where they were.
          FeedPresentation.content => KeyedSubtree(
              key: ValueKey('feed-${provider.feedGeneration}'),
              child: _buildFeedList(provider.filteredPosts),
            ),
        });
      },
    );
  }

  /// Fade one state into the next. Deliberately fade-only: a size or scale
  /// transition would make the swap itself the thing the user notices, which is
  /// the opposite of the point. The stack layout keeps both children at full
  /// size for the duration, so nothing collapses, expands or reflows.
  Widget _crossfade(Widget child) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      child: child,
    );
  }

  Widget _buildFeedList(List<PostModel> posts) {
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
        controller: _feedScroll,
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
          } else {
            // Organic impression — the weakest behavioural signal (0.05),
            // deduped per feed session so scrolling back and forth does
            // not tell the engine you love a post you scrolled past four
            // times.
            InteractionTracker.instance.trackImpression(post);
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
              // A closed listing answers in place instead of taking the
              // screen — the feed keeps its scroll position, filters and
              // search. See openPostFromFeed.
              openPostFromFeed(context, post);
            },
            // Requests and job posts both respond by applying, through the
            // one guarded flow. A job used to fall into the `else` here and
            // open a chat ("Enquire"), while the Jobs tab showed the same
            // job an "Apply" — one listing, two different verbs.
            onRespond: listingTakesApplications(post.type)
                ? () {
                    AuthGuard.requireAuth(
                      context,
                      action: post.type == PostType.job
                          ? 'apply for this job'
                          : 'offer service on this request',
                      onAuthenticated: () => applyToListing(context, post),
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
  }
}
