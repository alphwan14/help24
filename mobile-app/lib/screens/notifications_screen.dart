import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/app_notification.dart';
import '../models/post_model.dart';
import '../providers/connectivity_provider.dart';
import '../services/notification_store.dart';
import '../theme/app_theme.dart';
import '../utils/notification_sections.dart';
import '../widgets/loading_empty_offline.dart';
import '../utils/time_utils.dart';
import 'applications_screen.dart';
import 'approve_or_dispute_screen.dart';
import 'dispute_thread_screen.dart';
import 'job_lifecycle_screen.dart';
import 'promotion/campaign_detail_screen.dart';
import 'provider_profile_screen.dart';
import 'review_submission_screen.dart';
import 'messages_screen.dart';

// ─── Screen ───────────────────────────────────────────────────────────────────

/// The notification centre.
///
/// A REGISTER, NOT A FEED
/// ----------------------
/// This screen manages the record of real work, real money and real disputes, so
/// it is built like a statement rather than a timeline: sectioned, prioritised,
/// grouped, and calm. Every row answers five questions — what happened, who did
/// it, which job it concerns, when, and what to do next — and rows that have no
/// next step deliberately show no button, because an app whose buttons are
/// sometimes decoration teaches people not to trust its buttons.
///
/// It owns NO state. The list, the unread count, the cache, the realtime
/// subscription and the offline behaviour all live in [NotificationStore], which
/// is what makes the bell badge and this screen incapable of disagreeing. See
/// that class for the contracts; this file is presentation.
class NotificationsScreen extends StatefulWidget {
  final String userId;

  const NotificationsScreen({super.key, required this.userId});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final NotificationStore _store = NotificationStore.instance;
  final ScrollController _scroll = ScrollController();
  NotificationCategory? _filter;

  /// How close to the bottom counts as "asking for more history".
  static const double _paginateWithin = 400;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    _scroll.addListener(_maybePaginate);
    // Idempotent: the store is very likely already bound and warm, in which case
    // this is a silent refresh under content that is already on screen.
    unawaited(_store.bind(widget.userId));
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    _scroll.removeListener(_maybePaginate);
    _scroll.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  void _maybePaginate() {
    if (!_scroll.hasClients) return;
    final remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < _paginateWithin) unawaited(_store.loadMore());
  }

  Future<void> _tap(AppNotification n) async {
    // Read immediately and locally — the user has plainly seen it, and waiting
    // for a round trip to reflect that is how a register comes to feel laggy.
    unawaited(_store.markRead(n.id));
    if (mounted) await _navigate(n);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.darkBackground : AppTheme.lightBackground;
    final textPrimary =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final unread = _store.unreadCount;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              color: textPrimary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Notifications',
          style: TextStyle(
              color: textPrimary, fontWeight: FontWeight.w700, fontSize: 18),
        ),
        actions: [
          if (unread > 0)
            TextButton(
              onPressed: () => unawaited(_store.markAllRead()),
              child: const Text('Mark all read',
                  style: TextStyle(
                      color: AppTheme.primaryAccent,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ),
        ],
      ),
      body: ReconnectListener(
        onReconnect: () => unawaited(_store.refresh()),
        child: Column(
          children: [
            // Offline is a background state, not a takeover: the strip explains
            // why nothing new is arriving while the cached register below stays
            // completely readable.
            Consumer<ConnectivityProvider>(
              builder: (_, connectivity, __) => connectivity.isOffline
                  ? const OfflineBanner()
                  : const SizedBox.shrink(),
            ),
            _buildFilterBar(isDark),
            Expanded(child: _buildBody(isDark)),
          ],
        ),
      ),
    );
  }

  /// Category chips, offered only when there is something to filter.
  ///
  /// Built from what the user actually HAS, never from the full taxonomy — a
  /// chip for a category with nothing behind it is an invitation to an empty
  /// screen.
  Widget _buildFilterBar(bool isDark) {
    final categories = categoriesPresent(_store.all);
    if (categories.length < 2) return const SizedBox.shrink();

    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: [
          _chip('All', _filter == null, () => setState(() => _filter = null), isDark),
          for (final category in categories) ...[
            const SizedBox(width: 8),
            _chip(
              category.label,
              _filter == category,
              () => setState(
                  () => _filter = _filter == category ? null : category),
              isDark,
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap, bool isDark) {
    final border = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final idle = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Material(
      color: active
          ? AppTheme.primaryAccent.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: active ? AppTheme.primaryAccent : border),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? AppTheme.primaryAccent : idle,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    switch (_store.presentation) {
      case NotificationPresentation.loading:
        return const ConversationSkeletonList(itemCount: 5);

      case NotificationPresentation.failed:
        return ErrorRetryView(
          message: _store.error ?? 'Something went wrong.',
          onRetry: () => unawaited(_store.refresh()),
        );

      case NotificationPresentation.empty:
        return const EmptyStateView(
          icon: Icons.notifications_none_rounded,
          title: 'Nothing to report',
          subtitle:
              "Applications, payments, job updates and disputes will appear here.",
        );

      case NotificationPresentation.content:
        return _buildRegister(isDark);
    }
  }

  Widget _buildRegister(bool isDark) {
    final sections = buildSections(
      attention: _store.needsAttention,
      timeline: _store.timeline,
      now: DateTime.now(),
      categoryFilter: _filter,
    );

    if (sections.isEmpty) {
      // A filter with nothing behind it. Says exactly that, rather than
      // implying the whole register is empty.
      return EmptyStateView(
        icon: Icons.filter_alt_off_rounded,
        title: 'Nothing in ${_filter?.label ?? 'this category'}',
        subtitle: 'Choose another category to see the rest.',
        actions: [
          TextButton(
            onPressed: () => setState(() => _filter = null),
            child: const Text('Show all'),
          ),
        ],
      );
    }

    return RefreshIndicator(
      color: AppTheme.primaryAccent,
      onRefresh: _store.refresh,
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          for (final section in sections) ...[
            SliverToBoxAdapter(
              child: _SectionHeader(title: section.title, pinned: section.pinned),
            ),
            SliverList.builder(
              itemCount: section.groups.length,
              itemBuilder: (_, i) => _NotificationRow(
                key: ValueKey(section.groups[i].key),
                group: section.groups[i],
                onTap: _tap,
              ),
            ),
          ],
          if (_store.isLoadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  // ── Routing ───────────────────────────────────────────────────────────────

  /// Where a notification goes when tapped.
  ///
  /// Driven by the payload rather than by a `switch` over types, which is what
  /// makes it TOTAL: the previous router listed sixteen of the backend's
  /// twenty-two types and silently did nothing for the rest, so a rejected
  /// promotion or a received review was a row you could tap forever. Every
  /// notification now lands somewhere it can be acted on, and a type this build
  /// has never seen still routes on whatever context its data names.
  Future<void> _navigate(AppNotification n) async {
    final data = n.data;

    // Disputes are the most specific destination, and the thread is where the
    // conversation actually is.
    final disputeId = n.disputeId;
    if (disputeId != null && n.kind.category == NotificationCategory.disputes) {
      final threadTypes = {
        'dispute_message',
        'dispute_evidence_requested',
        'dispute_evidence_uploaded',
      };
      if (threadTypes.contains(n.type)) {
        await _push(DisputeThreadScreen(disputeId: disputeId));
        return;
      }
    }

    switch (n.type) {
      case 'chat_message':
        final chatId = n.chatId;
        if (chatId != null) {
          await _openChatById(chatId: chatId, userName: n.title);
        } else {
          _openMessages();
        }
        return;

      case 'provider_applied':
      case 'application_withdrawn':
        final postId = n.postId;
        if (postId != null) await _openApplications(postId: postId);
        return;

      case 'completion_requested':
        final postId = n.postId;
        if (postId != null) {
          await _push(ApproveOrDisputeScreen(
            postId: postId,
            clientUserId: widget.userId,
          ));
        }
        return;

      case 'review_requested':
        final postId = n.postId;
        if (postId != null) {
          await _push(ReviewSubmissionScreen(
            postId: postId,
            clientUserId: widget.userId,
          ));
        }
        return;

      case 'review_received':
        // The review lives on the recipient's own public profile — which is
        // both where it is displayed and where its effect on reputation is.
        await _push(ProviderProfileScreen(providerId: widget.userId));
        return;

      case 'provider_selected':
        final chatId = n.chatId ??
            (n.postId == null ? null : await _findChatByPost(postId: n.postId!));
        if (chatId != null) {
          await _openChatById(chatId: chatId, userName: 'Job chat');
        } else if (n.postId != null) {
          await _push(JobLifecycleScreen(postId: n.postId!));
        } else {
          _openMessages();
        }
        return;

      case 'promotion_payment_received':
      case 'promotion_live':
      case 'promotion_rejected':
      case 'promotion_completed':
        final campaignId = data['campaign_id']?.toString();
        if (campaignId != null && campaignId.isNotEmpty) {
          await _push(CampaignDetailScreen(
            campaignId: campaignId,
            uid: widget.userId,
          ));
        }
        return;

      case 'verification_approved':
      case 'badge_earned':
      case 'profile_updated':
        await _push(ProviderProfileScreen(providerId: widget.userId));
        return;
    }

    // Everything money- and job-shaped — and every type this build has never
    // heard of that still names a listing — resolves to the one screen that can
    // explain the whole state of that job.
    final postId = n.postId;
    if (postId != null) {
      await _push(JobLifecycleScreen(postId: postId));
      return;
    }
    final chatId = n.chatId;
    if (chatId != null) {
      await _openChatById(chatId: chatId, userName: n.title);
      return;
    }
    final fallbackDispute = n.disputeId;
    if (fallbackDispute != null) {
      await _push(DisputeThreadScreen(disputeId: fallbackDispute));
    }
    // No context at all: an announcement. The row itself was the message, and
    // navigating somewhere arbitrary would be worse than staying put.
  }

  Future<void> _push(Widget screen) async {
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  /// Open a chat, resolving the partner so the header shows a real person.
  ///
  /// The avatar columns are `avatar_url` with a `profile_image` fallback — the
  /// same pair every other author read in the app uses. This used to ask for
  /// `profile_picture_url`, which does not exist on `users`: the query threw,
  /// the failure was swallowed, and every chat opened from the bell showed a
  /// generic name and no picture.
  Future<void> _openChatById(
      {required String chatId, String userName = 'Chat'}) async {
    if (!mounted) return;
    String resolvedName = userName;
    String resolvedAvatar = '';
    String participantId = '';
    try {
      final chatRow = await Supabase.instance.client
          .from('chats')
          .select('user1, user2')
          .eq('id', chatId)
          .maybeSingle();
      if (chatRow != null) {
        final u1 = chatRow['user1'] as String? ?? '';
        final u2 = chatRow['user2'] as String? ?? '';
        participantId = (u1 == widget.userId) ? u2 : u1;
        if (participantId.isNotEmpty) {
          final userRow = await Supabase.instance.client
              .from('users')
              .select('name, avatar_url, profile_image')
              .eq('id', participantId)
              .maybeSingle();
          resolvedName = (userRow?['name'] as String?) ?? userName;
          final avatar = (userRow?['avatar_url'] as String?)?.trim() ?? '';
          final profileImage =
              (userRow?['profile_image'] as String?)?.trim() ?? '';
          resolvedAvatar = avatar.isNotEmpty ? avatar : profileImage;
        }
      }
    } catch (e) {
      debugPrint('[NOTIFICATIONS][NAV] partner load failed: $e');
    }

    await _push(ChatScreen(
      conversation: Conversation(
        id: chatId,
        participantId: participantId,
        userName: resolvedName,
        userAvatar: resolvedAvatar,
        lastMessage: '',
        lastMessageTime: DateTime.now(),
      ),
      currentUserId: widget.userId,
    ));
  }

  void _openMessages() {
    if (!mounted) return;
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const MessagesScreen()));
  }

  Future<void> _openApplications({required String postId}) async {
    try {
      final post = await Supabase.instance.client
          .from('posts')
          .select('id, title, author_user_id')
          .eq('id', postId)
          .maybeSingle();
      if (!mounted) return;
      if (post == null) {
        _openMessages();
        return;
      }
      await _push(ApplicationsScreen(
        postId: postId,
        postTitle: post['title'] as String? ?? 'Job',
        authorUserId: post['author_user_id'] as String? ?? widget.userId,
      ));
    } catch (e) {
      debugPrint('[NOTIFICATIONS][NAV] applications load failed: $e');
    }
  }

  Future<String?> _findChatByPost({required String postId}) async {
    try {
      final res = await Supabase.instance.client
          .from('chats')
          .select('id')
          .eq('post_id', postId)
          .or('user1.eq.${widget.userId},user2.eq.${widget.userId}')
          .maybeSingle();
      return res?['id'] as String?;
    } catch (e) {
      debugPrint('[NOTIFICATIONS][NAV] chat lookup failed: $e');
      return null;
    }
  }
}

// ─── Section header ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final bool pinned;

  const _SectionHeader({required this.title, required this.pinned});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = pinned
        ? AppTheme.primaryAccent
        : (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary);

    return Padding(
      padding: EdgeInsets.fromLTRB(20, pinned ? 14 : 22, 20, 8),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Row ──────────────────────────────────────────────────────────────────────

/// One row: a notification, or a collapsed group of them.
///
/// Restrained on purpose. Marketplaces that manage other people's money read as
/// registers — Stripe, Airbnb, Uber — and the register's job is to be scanned in
/// two seconds and trusted completely. So: one accent per tone, no gradients, no
/// motion beyond the expand, and no decoration that is not carrying information.
class _NotificationRow extends StatefulWidget {
  final NotificationGroup group;
  final Future<void> Function(AppNotification) onTap;

  const _NotificationRow({super.key, required this.group, required this.onTap});

  @override
  State<_NotificationRow> createState() => _NotificationRowState();
}

class _NotificationRowState extends State<_NotificationRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    if (!group.isGroup) {
      return _NotificationTile(
        notification: group.lead,
        onTap: () => widget.onTap(group.lead),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _NotificationTile(
          notification: group.lead,
          groupCount: group.length,
          groupUnread: group.unreadCount,
          expanded: _expanded,
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                  ),
                ),
              ),
              child: Column(
                children: [
                  for (final n in group.items.skip(1))
                    _NotificationTile(
                      notification: n,
                      dense: true,
                      onTap: () => widget.onTap(n),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final AppNotification notification;
  final VoidCallback onTap;

  /// Set when this tile is the lead of a collapsed group.
  final int? groupCount;
  final int groupUnread;
  final bool expanded;

  /// Members of an expanded group render smaller, so the group still reads as
  /// one item rather than as several that happen to be indented.
  final bool dense;

  const _NotificationTile({
    required this.notification,
    required this.onTap,
    this.groupCount,
    this.groupUnread = 0,
    this.expanded = false,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final textTertiary =
        isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;

    final kind = notification.kind;
    final tone = kind.tone.color(isDark);
    final unread = groupCount != null ? groupUnread > 0 : !notification.read;
    final isGroup = groupCount != null && groupCount! > 1;

    return Semantics(
      button: true,
      selected: unread,
      child: InkWell(
        onTap: onTap,
        child: Container(
          // The unread wash is the only background the register uses. It marks
          // the rows that still need something without turning the list into a
          // colour chart.
          color: unread ? tone.withValues(alpha: 0.055) : Colors.transparent,
          padding: EdgeInsets.fromLTRB(20, dense ? 11 : 15, 16, dense ? 11 : 15),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: EdgeInsets.all(dense ? 7 : 9),
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(kind.icon, color: tone, size: dense ? 16 : 19),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            isGroup
                                ? '$groupCount ${_pluralise(kind, groupCount!)}'
                                : notification.title,
                            style: TextStyle(
                              color: textPrimary,
                              fontWeight:
                                  unread ? FontWeight.w700 : FontWeight.w600,
                              fontSize: dense ? 13 : 14.5,
                              height: 1.25,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatRelativeTime(notification.createdAt),
                          style: TextStyle(color: textTertiary, fontSize: 11),
                        ),
                        if (unread) ...[
                          const SizedBox(width: 8),
                          Container(
                            width: 7,
                            height: 7,
                            margin: const EdgeInsets.only(top: 4),
                            decoration:
                                BoxDecoration(color: tone, shape: BoxShape.circle),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      notification.body,
                      style: TextStyle(
                          color: textSecondary,
                          fontSize: dense ? 12.5 : 13,
                          height: 1.4),
                      maxLines: dense ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // A group's lead offers expansion; a single row offers the
                    // action its kind defines. Nothing offers both, and a kind
                    // with no next step offers neither.
                    if (isGroup) ...[
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          Text(
                            expanded ? 'Hide' : 'Show all',
                            style: TextStyle(
                              color: AppTheme.primaryAccent,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Icon(
                            expanded
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                            size: 17,
                            color: AppTheme.primaryAccent,
                          ),
                        ],
                      ),
                    ] else if (kind.action != null && !dense) ...[
                      const SizedBox(height: 8),
                      Text(
                        kind.action!,
                        style: const TextStyle(
                          color: AppTheme.primaryAccent,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "3 new applications", "2 payment updates" — the group's headline, phrased
  /// from the category so it reads as English rather than as a type name.
  static String _pluralise(NotificationKind kind, int count) =>
      switch (kind.category) {
        NotificationCategory.applications => 'new applications',
        NotificationCategory.jobs => 'job updates',
        NotificationCategory.payments => 'payment updates',
        NotificationCategory.disputes => 'dispute updates',
        NotificationCategory.reviews => 'new reviews',
        NotificationCategory.messages => 'new messages',
        NotificationCategory.promotions => 'campaign updates',
        NotificationCategory.provider => 'profile updates',
        NotificationCategory.system => 'system notices',
        NotificationCategory.support => 'support updates',
      };
}

// ─── Badge ────────────────────────────────────────────────────────────────────

/// The bell's unread badge.
///
/// A thin view onto [NotificationStore] and nothing more. It used to own a
/// count, a realtime subscription and a fetch of its own, all of which
/// disagreed with the screen's — and because it re-queried the whole count for
/// every realtime event with no sequencing, "mark all read" made it step
/// through arbitrary values before settling. It cannot now: there is one number
/// in the app, it changes on four events, and this widget only renders it.
///
/// The public API ([userId] + [child]) is unchanged, so the call site did not
/// have to move.
class NotificationBadge extends StatefulWidget {
  final String userId;
  final Widget child;

  const NotificationBadge({
    super.key,
    required this.userId,
    required this.child,
  });

  @override
  State<NotificationBadge> createState() => _NotificationBadgeState();
}

class _NotificationBadgeState extends State<NotificationBadge>
    with WidgetsBindingObserver {
  final NotificationStore _store = NotificationStore.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store.addListener(_onStoreChanged);
    unawaited(_store.bind(widget.userId));
  }

  @override
  void didUpdateWidget(covariant NotificationBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      unawaited(_store.bind(widget.userId));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app is a good moment to re-sync — but it is a REFRESH,
    // which cannot clear the badge or blank the list. The count only moves if
    // the server reports a different one.
    if (state == AppLifecycleState.resumed) unawaited(_store.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final unread = _store.unreadCount;
    if (unread == 0) return widget.child;
    return Badge(
      label: Text(unread > 99 ? '99+' : '$unread'),
      backgroundColor: AppTheme.errorRed,
      child: widget.child,
    );
  }
}
