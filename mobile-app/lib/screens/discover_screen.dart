import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_icons.dart';
import '../models/filter_selection.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/connectivity_provider.dart';
import '../providers/location_provider.dart';
import '../theme/tokens.dart';
import '../widgets/primitives.dart';
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
import '../services/launch_sequence.dart';
import '../services/promotion_service.dart';
import '../services/urgent_seen_store.dart';
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

  /// Slots that arrived while the reader was mid-scroll, waiting for a moment
  /// when applying them costs nothing. See [_applySlots].
  SlotsResult? _heldSlots;

  /// Mirrors what was last reported to the provider, so scroll notifications
  /// that change nothing do no work at all.
  bool _engaged = false;

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
      // The seen set has to be in memory before the first frame that draws a
      // count, or the chip flashes the full inventory and then corrects
      // itself — which reads as the number being wrong rather than as it
      // loading.
      unawaited(UrgentSeenStore.instance.ensureLoaded());
    });
  }

  /// Tell the provider whether someone is reading, so a rebuild that finishes
  /// mid-scroll is OFFERED rather than applied.
  ///
  /// Returning to the top is also the moment any sponsored slots that arrived
  /// mid-scroll become free to compose.
  void _reportEngagement() {
    if (!mounted || !_feedScroll.hasClients) return;
    final engaged = _feedScroll.offset > _engagedOffset;
    if (engaged == _engaged) return;
    _engaged = engaged;
    context.read<AppProvider>().setFeedEngaged(engaged);
    final held = _heldSlots;
    if (!engaged && held != null) _applySlots(held);
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

  /// Maps the current feed context to a promotion placement and fetches
  /// slots. Sequence-guarded so a slow older response never overwrites a
  /// newer one.
  Future<void> _loadSponsoredSlots() async {
    final provider = context.read<AppProvider>();
    final location = context.read<LocationProvider>();

    // Sponsored subjects are offer posts — the Requests tab shows none.
    if (_tabIndex == 1) {
      _heldSlots = null;
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
    _applySlots(result);
  }

  /// Compose [result] into the feed — but only when doing so moves nothing the
  /// reader is looking at.
  ///
  /// WHY THIS IS GATED AT ALL
  /// ------------------------
  /// Sponsored slots are not an overlay on the feed, they are rows IN it
  /// ([FeedComposer] inserts them between organic cards). So applying them to a
  /// list already on screen pushes every card below the first slot down — the
  /// same disturbance a re-ranking causes, from a source the reader has even
  /// less ability to connect to anything they did. It was the second feed
  /// installation hiding in plain sight: the launch fetch was fired from
  /// Discover's post-frame callback and landed a beat after the feed appeared.
  ///
  /// The launch case is now free — the shell is built behind the splash, so
  /// this resolves before anyone sees the list. This gate covers the rest: a
  /// slot response that arrives while somebody is reading waits until they come
  /// back to the top, which [_reportEngagement] notices.
  void _applySlots(SlotsResult result) {
    if (_engaged && !LaunchSequence.isHoldingSplash) {
      _heldSlots = result;
      return;
    }
    _heldSlots = null;
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
    // 'Jobs' maps to FeedScope.jobs, which the server has always served and
    // which the standalone Jobs tab used. Discover reaches it through the same
    // loadPosts path as every other scope — no second corpus.
    const filters = ['All', 'Requests', 'Offers', 'Jobs'];
    provider.setSelectedFilter(filters[tab]);
    _loadSponsoredSlots();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
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
            padding: const EdgeInsets.fromLTRB(AppSpace.gutter, AppSpace.xs, AppSpace.gutter, 0),
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
                          icon: const Icon(AppIcons.notifications),
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
                    //
                    // Selected rather than Consumed: AppProvider notifies on
                    // every keystroke in the search box, every filter change and
                    // every load transition, and this pill cares about exactly
                    // one number. A plain Consumer rebuilt it for all of them.
                    // The count is UNSEEN open emergencies, not all of them.
                    //
                    // It used to be the whole open inventory, which is a true
                    // fact drawn in a shape that means something else: a red
                    // count says "N things you have not dealt with", so it
                    // never moving — read the request, come back, still
                    // `Urgent · 1` — taught the reader to stop looking. That is
                    // the one thing an emergency surface cannot afford.
                    //
                    // Listening to BOTH: the provider for what is open, and the
                    // seen store for what has been looked at. Either changing
                    // has to move the number.
                    ListenableBuilder(
                      listenable: UrgentSeenStore.instance,
                      builder: (context, _) => Selector<AppProvider, int>(
                      // Only requests whose window is still open. The list is
                      // loaded once and held, so without this the badge kept
                      // counting emergencies that had already expired.
                      selector: (_, provider) =>
                          UrgentSeenStore.instance.unseenCount(
                        openUrgentPosts(provider.urgentPosts, DateTime.now())
                            .map((p) => p.id),
                      ),
                      builder: (_, urgentCount, __) {
                        // Emergency entry. It used to be a bordered red pill
                        // with a bold red label and a filled red counter —
                        // three reds and a boundary, competing with the screen
                        // title beside it. It is one chip now, in the critical
                        // tone every other urgent thing in the app uses, and
                        // the count rides inside the label rather than on a
                        // second badge.
                        //
                        // Still red, still first thing you see after the title.
                        // Just not shouting over it.
                        return Semantics(
                          button: true,
                          label: urgentCount > 0
                              ? 'Urgent requests, $urgentCount new'
                              : 'Urgent requests',
                          child: GestureDetector(
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const UrgentRequestsScreen()),
                            ),
                            behavior: HitTestBehavior.opaque,
                            child: AppChip(
                              label: urgentCount > 0
                                  ? 'Urgent · $urgentCount'
                                  : 'Urgent',
                              icon: AppIcons.urgent,
                              tone: ChipTone.critical,
                              size: ChipSize.md,
                            ),
                          ),
                        );
                      },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── Search bar ───────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.gutter, AppSpace.md, AppSpace.gutter, 0),
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
                  style: AppTypeScale.bodyM.copyWith(
                    fontFamily: AppTypeScale.family,
                    color: c.contentPrimary,
                  ),
                  decoration: InputDecoration(
                    // "Search all posts..." named the database table, not the
                    // thing the user wants. Discover is where someone answers
                    // "what can I get done here", and the field is the first
                    // place that question can be answered.
                    hintText: _tabIndex == 0
                        ? 'Search services and requests'
                        : _tabIndex == 1
                            ? 'Search requests'
                            : 'Search services',
                    // 48, down from ~64. The field was the tallest element on
                    // the screen and it is not the primary action.
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.md, vertical: AppSpace.md + 2),
                    prefixIcon: Icon(AppIcons.search,
                        size: 20, color: c.contentTertiary),
                    prefixIconConstraints: const BoxConstraints(
                        minWidth: 44, minHeight: 44),
                    suffixIcon: searchText.isNotEmpty
                        ? IconButton(
                            icon: const Icon(AppIcons.close, size: 20),
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

          // ── Scopes (scrolling) + Filters (pinned) ────────────
          //
          // Four scopes no longer fit on one line at 384 dp, so the pills
          // scroll. The filter control sits OUTSIDE that scroll view: a
          // control that can slide off the screen edge is a control the user
          // cannot find, and it is the one thing in this row that is not a
          // scope.
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.md),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.gutter),
                    child: Row(
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
                        const SizedBox(width: FilterPill.gap),
                        // Jobs, which used to be a tab of its own in the
                        // bottom bar. It is a scope over the same corpus,
                        // reached by the same request — so it belongs beside
                        // the other scopes, not beside Messages and Profile.
                        FilterPill(
                          label: 'Jobs',
                          isActive: _tabIndex == 3,
                          onTap: () => _switchToTab(3),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Padding(
                  padding: const EdgeInsets.only(right: AppSpace.gutter),
                  child: Consumer<AppProvider>(
                    builder: (context, provider, _) {
                      return GestureDetector(
                      onTap: () async {
                        // The sheet ANSWERS; it does not apply itself. A null
                        // answer means the user left without searching — Exit,
                        // a swipe down, or the system back gesture — and a
                        // cancelled sheet must cost nothing. This used to call
                        // applyFilters() unconditionally, so dismissing the
                        // sheet untouched issued a full ranked request and
                        // reinstalled the feed.
                        final selection =
                            await showModalBottomSheet<FilterSelection>(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          // THE SHEET IS SIZED AGAINST THE SPACE ABOVE THE
                          // KEYBOARD, NOT AGAINST THE SCREEN.
                          //
                          // `DraggableScrollableSheet` takes fractions of the
                          // box it is given. That box used to be the whole
                          // screen, so 0.85 stayed 0.85 of the screen when the
                          // keyboard opened and everything in the bottom ~45%
                          // went behind it — including the Search and Exit
                          // buttons, which are outside the scroll view and so
                          // could not be scrolled back into reach. Verified on
                          // the S20+: typing a custom profession left no way to
                          // press Search without dismissing the keyboard first.
                          //
                          // Taking the inset off the box is the structural fix,
                          // not an offset: the fractions are unchanged and every
                          // screen size gets the same behaviour, because the box
                          // is now whatever is actually visible.
                          builder: (context) => Padding(
                            padding: EdgeInsets.only(
                              bottom: MediaQuery.viewInsetsOf(context).bottom,
                            ),
                            child: DraggableScrollableSheet(
                              initialChildSize: 0.85,
                              minChildSize: 0.5,
                              maxChildSize: 0.95,
                              // Without this the sheet expands to fill the box
                              // regardless of its fractions, which is what makes
                              // the resize look like it never happened.
                              expand: false,
                              builder: (context, scrollController) =>
                                  FilterBottomSheet(
                                scrollController: scrollController,
                              ),
                            ),
                          ),
                        );
                        if (!mounted || selection == null) return;
                        // One request, and only when something actually changed
                        // — applyFilterSelection reports which it was.
                        final changed =
                            await provider.applyFilterSelection(selection);
                        if (mounted && changed) _loadSponsoredSlots();
                      },
                      // Sized and shaped as a FilterPill, because it belongs to
                      // that row. It used to be a 12-radius square beside three
                      // 24-radius capsules of a different height, which read as
                      // a stray control that had wandered in from another
                      // screen — and it was unlabelled to a screen reader.
                      child: Semantics(
                        button: true,
                        label: provider.hasActiveFilters
                            ? 'Filters, active'
                            : 'Filters',
                        child: Container(
                          height: 40,
                          width: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: provider.hasActiveFilters
                                ? c.accentFill
                                : c.surfaceSunken,
                            borderRadius: AppRadius.pillAll,
                            border: provider.hasActiveFilters
                                ? null
                                : Border.all(color: c.borderHairline),
                          ),
                          // Active state is the same brand-gold fill a selected
                          // pill uses, so "a filter is on" reads as selection
                          // rather than as a separate decoration with its own
                          // dot.
                          child: Icon(
                            AppIcons.filter,
                            size: 18,
                            color: provider.hasActiveFilters
                                ? c.contentOnAccent
                                : c.contentSecondary,
                          ),
                        ),
                      ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // ── Result count, while searching ────────────────────
          //
          // This used to read `Showing all posts for "plumber"` in ITALIC — the
          // only italic text in the app — and it restated two things already on
          // screen: the query is in the field above it, and the tab is the
          // selected pill next to that. A count is the one thing the user
          // cannot see for themselves, and it is what tells them whether to
          // refine or to scroll.
          if (searchText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.gutter, AppSpace.md, AppSpace.gutter, 0),
              child: Selector<AppProvider, int>(
                selector: (_, p) => p.filteredPosts.length,
                builder: (_, count, __) => Text(
                  count == 1 ? '1 result' : '$count results',
                  style: AppTypeScale.meta.copyWith(
                    fontFamily: AppTypeScale.family,
                    color: c.contentTertiary,
                  ),
                ),
              ),
            ),

          const SizedBox(height: AppSpace.md),

          // ── Feed ─────────────────────────────────────────────
          //
          // No overlay. A pill announcing newly computed recommendations used
          // to float here, and the Stack existed only to hold it.
          // Recommending is Help24's job: a better ranking now lands on its own
          // at the next moment landing is free — the reader returning to the
          // top (AppProvider.setFeedEngaged) or leaving Discover
          // (setDiscoverVisible). Both were already the conditions under which
          // the prompt was safe to tap, so what has been removed is the asking,
          // not the safety.
          Expanded(child: _buildPostsFeed()),
        ],
      ),
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
              icon: AppIcons.empty,
              title: 'No posts found',
              subtitle: 'Try adjusting your filters or search. Pull to refresh.',
              actions: [
                TextButton.icon(
                  onPressed: _refreshPosts,
                  icon: const Icon(AppIcons.refresh, size: 20),
                  label: const Text('Refresh'),
                ),
                if (provider.hasActiveFilters)
                  TextButton.icon(
                    onPressed: () => provider.clearFilters(),
                    icon: const Icon(AppIcons.dismiss, size: 20),
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
  ///
  /// Instantaneous while the launch splash is up. Behind an opaque screen there
  /// is nothing to smooth, and a transition still running when the splash
  /// starts to fade would be uncovered halfway through — the feed would appear
  /// to fade in on top of itself, which is a blink wearing the splash's name.
  /// Zero duration means the last state change before the handover is fully
  /// painted in the frame the reveal waits for.
  Widget _crossfade(Widget child) {
    return AnimatedSwitcher(
      duration: LaunchSequence.isHoldingSplash
          ? Duration.zero
          : const Duration(milliseconds: 240),
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
        padding: const EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter,
            AppSpace.fabClearance),
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
