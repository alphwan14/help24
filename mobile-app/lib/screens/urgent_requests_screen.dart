import 'dart:async';

import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:provider/provider.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/location_provider.dart';
import '../utils/post_ownership.dart';
import '../utils/proximity.dart';
import '../utils/urgent_window.dart';
import '../widgets/auth_guard.dart';
import '../widgets/loading_empty_offline.dart';
import '../widgets/post_card.dart';
import '../widgets/post_flows.dart';

/// Urgent requests — the SAME marketplace as Discover, filtered to emergencies.
///
/// WHAT THIS SCREEN USED TO BE
/// ---------------------------
/// A second, weaker marketplace. It was the only listing surface never migrated
/// to the shared modules, and it disagreed with the rest of the app on all
/// three of them:
///
///   * a hand-rolled card showing title, distance and age — no author, no
///     avatar, no reputation, no price, no photos. You could not see who was
///     asking for help;
///   * a bottom sheet that showed LESS than a Discover card does at a glance,
///     in place of the detail screen;
///   * "Offer Help Now" opened a private CHAT. Urgent posts are requests, and
///     everywhere else in Help24 a request is answered with an APPLICATION.
///
/// That third divergence was the expensive one. The request lifecycle — select
/// provider → assign → escrow → complete → review — runs entirely on the
/// `applications` table, so a chat-only response was a dead end: it never
/// reached the author's applicants list, never entered payment protection, and
/// skipped every guard the shared flow performs (ownership, duplicates, closed
/// listings, and the provider-ready gate that ensures whoever answers can
/// actually be paid). Urgent is where money moves fastest and trust matters
/// most — the worst surface on which to bypass escrow.
///
/// It now renders [PostCard], opens with [openPostFromFeed] and responds with
/// [applyToListing] — byte-identical to Discover. What stays urgency-specific is
/// what genuinely is: distance to the request, and a live countdown on the
/// window.
class UrgentRequestsScreen extends StatefulWidget {
  const UrgentRequestsScreen({super.key});

  @override
  State<UrgentRequestsScreen> createState() => _UrgentRequestsScreenState();
}

class _UrgentRequestsScreenState extends State<UrgentRequestsScreen> {
  /// Drives the countdowns and drops posts whose window closes while the screen
  /// is open. Ten seconds is well inside the resolution of a "N min left" label
  /// and costs one rebuild of a short list.
  static const Duration _tick = Duration(seconds: 10);
  Timer? _ticker;

  /// One clock for the whole frame, so every card on a rebuild counts down from
  /// the same instant and the expiry filter agrees with the labels it filtered.
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(_tick, (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _load();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Single reload path shared by first load, pull-to-refresh, the failure-state
  /// Retry button, and automatic recovery on reconnect.
  Future<void> _load() {
    final location = context.read<LocationProvider>();
    return context.read<AppProvider>().loadUrgentPosts(
          userLatitude: location.latitude,
          userLongitude: location.longitude,
        );
  }

  @override
  Widget build(BuildContext context) {
    final location = context.watch<LocationProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Urgent Help Needed')),
      body: ReconnectListener(
        onReconnect: _load,
        child: Consumer<AppProvider>(
          builder: (context, provider, _) {
            // Expiry is a property of the post and the clock, not of when the
            // query last ran: a request whose hour ran out mid-session leaves
            // the list here rather than sitting on it still labelled URGENT.
            final posts = openUrgentPosts(provider.urgentPosts, _now);

            if (provider.isLoadingUrgentPosts && posts.isEmpty) {
              return const FeedSkeletonList();
            }

            if (posts.isEmpty) {
              // Loading finished with nothing to show — distinguish a real
              // failure (offer Retry) from a genuinely empty area (reassure).
              final Widget state = provider.urgentError != null
                  ? ErrorRetryView(message: provider.urgentError!, onRetry: _load)
                  : const EmptyStateView(
                      icon: Iconsax.flash_1,
                      title: 'No urgent requests nearby',
                      subtitle:
                          "When someone nearby needs urgent help, it'll appear here.",
                    );
              // Keep it pull-to-refreshable so the user is never stuck.
              return RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.7,
                      child: state,
                    ),
                  ],
                ),
              );
            }

            return RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                itemCount: posts.length,
                itemBuilder: (context, index) {
                  final post = posts[index];
                  return PostCard(
                    post: post,
                    // The two facts that are genuinely urgency-specific. Every
                    // other thing on this card — author, avatar, reputation,
                    // price, photos, owner detection, CTA — is the shared card
                    // doing what it already does on every other surface.
                    distanceLabel: formatDistanceLabelOrNull(
                      distanceBetween(
                        viewerLatitude: location.latitude,
                        viewerLongitude: location.longitude,
                        targetLatitude: post.latitude,
                        targetLongitude: post.longitude,
                      ),
                    ),
                    urgentCountdown: urgentCountdownFor(post, _now),
                    // Identical to Discover: a closed listing answers in place
                    // and keeps your position in the list; the author and the
                    // selected provider get the full screen, which is where the
                    // applicants and the lifecycle actions live.
                    onTap: () => openPostFromFeed(context, post),
                    onRespond: () => _respond(post),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  /// THE one apply path, reached exactly as Discover reaches it.
  ///
  /// Urgent posts are requests, so `listingTakesApplications` is true for every
  /// post on this screen — but the check is written out rather than assumed, so
  /// this cannot silently become wrong if the urgency query ever widens.
  void _respond(PostModel post) {
    if (!listingTakesApplications(post.type)) {
      AuthGuard.requireAuth(
        context,
        action: 'enquire about this service',
        onAuthenticated: () => openPrivateChat(context, post),
      );
      return;
    }
    AuthGuard.requireAuth(
      context,
      action: 'offer help on this urgent request',
      onAuthenticated: () => applyToListing(context, post),
    );
  }
}
