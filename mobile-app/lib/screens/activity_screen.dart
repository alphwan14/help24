import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';
import '../widgets/auth_guard.dart';
import '../widgets/filter_pill.dart';
import '../widgets/loading_empty_offline.dart';
import 'my_applications_screen.dart';
import 'my_posts_screen.dart';
import 'saved_screen.dart';
import 'service_history_screen.dart';

/// ACTIVITY — the tab the product was missing.
///
/// ── What it replaces ────────────────────────────────────────────────────
/// The Jobs tab, which held a *filter over the same corpus Discover already
/// serves* (`FeedScope.jobs`, one wire value, one request) and, at the time of
/// writing, one listing. It is now a scope pill in Discover's own row.
///
/// ── The gap it fills ────────────────────────────────────────────────────
/// Everything about work the user is actually *doing* — their listings, the
/// applicants on them, the lifecycle, the money, the receipts — was reachable
/// only by finding the listing again in a feed and opening it, or by scrolling
/// a Profile screen that also held theme, language and the privacy policy.
/// There was no answer to "what is happening with my work right now?".
///
/// ── The three scopes ────────────────────────────────────────────────────
/// **My posts** is work you are paying for, **Applied** is work you are asking
/// to be paid for, and **Saved** is neither yet. They belong on one tab
/// because they are one question — "what is happening with my work?" — asked
/// from whichever side of the marketplace you are on today. Help24 has no
/// separate buyer and seller mode, and this is the surface where that shows.
///
/// Applied was the last of the three to exist: `getMyApplications` was called
/// on every sign-in, but only its post IDs were kept — enough to make a feed
/// card say "Applied" and nothing more — so no screen anywhere rendered the
/// list. See [MyApplicationsScreen].
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    // Palette is read by the children; the header uses theme text styles.
    final auth = context.watch<AuthProvider>();
    final uid = auth.currentUserId ?? '';
    final applied = context.select<AppProvider, int>((p) => p.appliedCount);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpace.gutter, AppSpace.xs, AppSpace.gutter, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Activity',
                    style: Theme.of(context).textTheme.headlineMedium),
                // Service history is a record, not live activity, so it is an
                // action here rather than a fourth scope — and it keeps its
                // own screen, which already has the tab structure that
                // "bought" and "worked" need.
                //
                // There is deliberately NO notification bell here. It was
                // added on the reasoning that notifications are mostly about
                // your activity, but Discover's header already owns it, and
                // two bells on two tabs is one control with two homes and two
                // unread counts to keep agreeing. Same repetition the "My
                // Activity" block in Profile turned out to be.
                IconButton(
                  icon: const Icon(AppIcons.serviceHistory),
                  tooltip: 'Service history',
                  onPressed: uid.isEmpty
                      ? null
                      : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => ServiceHistoryScreen(uid: uid)),
                          ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.md),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
              child: Row(
                children: [
                  FilterPill(
                    label: 'My posts',
                    isActive: _tab == 0,
                    onTap: () => setState(() => _tab = 0),
                  ),
                  const SizedBox(width: FilterPill.gap),
                  FilterPill(
                    label: 'Applied',
                    isActive: _tab == 1,
                    onTap: () => setState(() => _tab = 1),
                  ),
                  const SizedBox(width: FilterPill.gap),
                  FilterPill(
                    label: 'Saved',
                    isActive: _tab == 2,
                    onTap: () => setState(() => _tab = 2),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          Expanded(
            child: uid.isEmpty
                ? EmptyStateView(
                    icon: AppIcons.myPosts,
                    title: 'Nothing here yet',
                    subtitle: 'Sign in to see the work you have posted, '
                        'applied for and saved.',
                    actions: [
                      FilledButton(
                        onPressed: () => AuthGuard.requireAuth(
                          context,
                          action: 'see your activity',
                          onAuthenticated: () {},
                        ),
                        child: const Text('Sign in'),
                      ),
                    ],
                  )
                // Keyed by uid so switching account rebuilds rather than
                // showing the previous person's work while the new one loads.
                : IndexedStack(
                    index: _tab,
                    children: [
                      MyPostsScreen(
                          key: ValueKey('activity_posts_$uid'),
                          userId: uid,
                          embedded: true),
                      // Also keyed by how many things this person has applied
                      // to. The tabs live in an IndexedStack and keep their
                      // state, so applying and then walking straight here
                      // would otherwise show a list fetched before the apply.
                      // The count only moves when you apply, which is exactly
                      // when the list is stale.
                      MyApplicationsScreen(
                          key: ValueKey('activity_applied_${uid}_$applied'),
                          userId: uid,
                          embedded: true),
                      SavedScreen(
                          key: ValueKey('activity_saved_$uid'),
                          userId: uid,
                          embedded: true),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
