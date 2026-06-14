import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/post_model.dart';
import '../theme/app_theme.dart';
import '../utils/time_utils.dart';
import 'applications_screen.dart';
import 'approve_or_dispute_screen.dart';
import 'messages_screen.dart';

// ─── Model ────────────────────────────────────────────────────────────────────

class AppNotification {
  final String id;
  final String type;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final bool read;
  final DateTime createdAt;

  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.data,
    required this.read,
    required this.createdAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    return AppNotification(
      id: json['id'] as String,
      type: json['type'] as String? ?? '',
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      data: (json['data'] as Map<String, dynamic>?) ?? {},
      read: json['read'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

// ─── Service ──────────────────────────────────────────────────────────────────

class NotificationsDb {
  static SupabaseClient get _db => Supabase.instance.client;

  static Future<List<AppNotification>> fetchForUser(String userId,
      {int limit = 50}) async {
    final res = await _db
        .from('notifications')
        .select()
        .eq('user_id', userId)
        .neq('type', 'chat_message')   // chat messages belong in the Messages tab, not the bell
        .order('created_at', ascending: false)
        .limit(limit);
    return (res as List<dynamic>)
        .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<int> unreadCount(String userId) async {
    final res = await _db
        .from('notifications')
        .select('id')
        .eq('user_id', userId)
        .neq('type', 'chat_message')   // exclude chat_message from bell badge
        .eq('read', false);
    return (res as List<dynamic>).length;
  }

  static Future<void> markAllRead(String userId) async {
    await _db
        .from('notifications')
        .update({'read': true})
        .eq('user_id', userId)
        .eq('read', false);
  }

  static Future<void> markRead(String notificationId) async {
    await _db
        .from('notifications')
        .update({'read': true})
        .eq('id', notificationId);
  }
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class NotificationsScreen extends StatefulWidget {
  final String userId;

  const NotificationsScreen({super.key, required this.userId});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<AppNotification> _notifications = [];
  bool _loading = true;
  String? _error;
  RealtimeChannel? _subscription;

  @override
  void initState() {
    super.initState();
    _load();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    _subscription?.unsubscribe();
    super.dispose();
  }

  void _subscribeRealtime() {
    debugPrint('[NOTIFICATIONS][REALTIME] Subscribing for userId=${widget.userId}');
    _subscription = Supabase.instance.client
        .channel('notifications:${widget.userId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: widget.userId,
          ),
          callback: (payload) {
            debugPrint(
              '[NOTIFICATIONS][REALTIME] INSERT received — '
              'table=${payload.table} schema=${payload.schema}',
            );
            try {
              final newNotification =
                  AppNotification.fromJson(payload.newRecord);
              debugPrint(
                '[NOTIFICATIONS][REALTIME] parsed type=${newNotification.type} '
                'title="${newNotification.title}"',
              );
              // Chat messages are surfaced in the Messages tab, not the bell.
              if (newNotification.type == 'chat_message') return;
              if (mounted) {
                setState(() {
                  _notifications = [newNotification, ..._notifications];
                });
              }
            } catch (e) {
              debugPrint('[NOTIFICATIONS][ERROR] realtime parse error: $e');
            }
          },
        )
        .subscribe((status, [error]) {
          debugPrint('[NOTIFICATIONS][REALTIME] status=$status error=$error');
        });
  }

  Future<void> _load() async {
    debugPrint('[NOTIFICATIONS][AUTH] userId=${widget.userId}');
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      debugPrint('[NOTIFICATIONS][QUERY] fetching notifications for userId=${widget.userId}');
      final data = await NotificationsDb.fetchForUser(widget.userId);
      debugPrint('[NOTIFICATIONS][RESULT] loaded ${data.length} notifications');
      for (final n in data) {
        debugPrint(
          '[NOTIFICATIONS][ITEM] id=${n.id} type=${n.type} read=${n.read} '
          'title="${n.title}"',
        );
      }
      if (mounted) setState(() => _notifications = data);
    } catch (e) {
      debugPrint('[NOTIFICATIONS][ERROR] load failed: $e');
      if (mounted) setState(() => _error = 'Failed to load notifications.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markAllRead() async {
    await NotificationsDb.markAllRead(widget.userId);
    if (mounted) {
      setState(() {
        _notifications = _notifications
            .map((n) => AppNotification(
                  id: n.id,
                  type: n.type,
                  title: n.title,
                  body: n.body,
                  data: n.data,
                  read: true,
                  createdAt: n.createdAt,
                ))
            .toList();
      });
    }
  }

  Future<void> _tapNotification(AppNotification n) async {
    // Mark read immediately (optimistic — don't wait for DB).
    if (!n.read) {
      unawaited(NotificationsDb.markRead(n.id));
      if (mounted) {
        setState(() {
          _notifications = _notifications
              .map((x) => x.id == n.id
                  ? AppNotification(
                      id: x.id, type: x.type, title: x.title, body: x.body,
                      data: x.data, read: true, createdAt: x.createdAt)
                  : x)
              .toList();
        });
      }
    }
    if (mounted) await _navigateFromNotification(n);
  }

  // ── Centralised notification router ─────────────────────────────────────────

  Future<void> _navigateFromNotification(AppNotification n) async {
    final data = n.data;
    debugPrint('[NOTIFICATIONS][NAV] type=${n.type} data=$data');

    switch (n.type) {
      // ── Chat message → open the exact conversation ─────────────────────────
      case 'chat_message':
        final chatId = data['chat_id'] as String?;
        if (chatId != null && chatId.isNotEmpty) {
          debugPrint('[NAV][OPEN_CHAT] chat_message chatId=$chatId');
          await _openChatById(chatId: chatId, userName: n.title);
        }
        break;

      // ── Provider applied → open the applications list for the post ─────────
      case 'provider_applied':
        final postId = data['post_id'] as String?;
        if (postId != null && postId.isNotEmpty) {
          debugPrint('[NAV][OPEN_APPLICATIONS] provider_applied postId=$postId');
          await _openApplicationsFromBell(postId: postId);
        }
        break;

      // ── Completion requested → open approve/dispute screen ─────────────────
      case 'completion_requested':
        final postId = data['post_id'] as String?;
        if (postId != null && postId.isNotEmpty) {
          debugPrint('[NAV][OPEN_APPROVAL] completion_requested postId=$postId');
          await _openApprovalFromBell(postId: postId);
        }
        break;

      // ── Job lifecycle → open the job chat (use chat_id if present) ─────────
      case 'provider_selected':
      case 'payment_secured':
      case 'job_approved':
      case 'payout_released':
      case 'escrow_released':
      case 'dispute_opened':
      case 'dispute_resolved_release':
      case 'dispute_resolved_refund':
      case 'dispute_resolved_partial':
        final lcChatId = data['chat_id'] as String?;
        final lcPostId = data['post_id'] as String?;
        if (lcChatId != null && lcChatId.isNotEmpty) {
          debugPrint('[NAV][OPEN_CHAT] ${n.type} chatId=$lcChatId');
          await _openChatById(chatId: lcChatId, userName: 'Job Chat');
        } else if (lcPostId != null && lcPostId.isNotEmpty) {
          debugPrint('[NAV][OPEN_CHAT] ${n.type} postId=$lcPostId — looking up chat');
          final foundId = await _findChatByPost(postId: lcPostId);
          if (foundId != null && mounted) {
            await _openChatById(chatId: foundId, userName: 'Job Chat');
          } else if (mounted) {
            _openMessages();
          }
        }
        break;

      default:
        debugPrint('[NOTIFICATIONS][NAV] unknown type=${n.type} — no navigation');
        break;
    }
  }

  /// Open ChatScreen for a given chatId. Loads the partner's name/avatar so the
  /// chat header always shows the real user's name rather than a generic placeholder.
  Future<void> _openChatById({required String chatId, String userName = 'Chat'}) async {
    if (!mounted) return;
    debugPrint('[NOTIFICATIONS][NAV] opening ChatScreen chatId=$chatId');

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
              .select('name, profile_picture_url')
              .eq('id', participantId)
              .maybeSingle();
          resolvedName = (userRow?['name'] as String?) ?? userName;
          resolvedAvatar = (userRow?['profile_picture_url'] as String?) ?? '';
        }
      }
    } catch (e) {
      debugPrint('[NOTIFICATIONS][NAV] partner name load failed: $e');
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          conversation: Conversation(
            id: chatId,
            participantId: participantId,
            userName: resolvedName,
            userAvatar: resolvedAvatar,
            lastMessage: '',
            lastMessageTime: DateTime.now(),
          ),
          currentUserId: widget.userId,
        ),
      ),
    );
  }

  /// Navigate to Messages tab (fall-back when no specific chat is found).
  void _openMessages() {
    debugPrint('[NOTIFICATIONS][NAV] falling back to MessagesScreen');
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MessagesScreen()),
    );
  }

  /// Navigate to ApproveOrDisputeScreen, fetching required data first.
  Future<void> _openApprovalFromBell({required String postId}) async {
    try {
      final results = await Future.wait([
        Supabase.instance.client
            .from('posts')
            .select('id, title')
            .eq('id', postId)
            .maybeSingle(),
        Supabase.instance.client
            .from('job_completions')
            .select('id, provider_note')
            .eq('post_id', postId)
            .eq('status', 'pending_approval')
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle(),
      ]);

      if (!mounted) return;
      final post = results[0] as Map<String, dynamic>?;
      final completion = results[1] as Map<String, dynamic>?;

      if (post == null) {
        debugPrint('[NAV][OPEN_APPROVAL] post not found postId=$postId — fallback');
        _openMessages();
        return;
      }

      final txRes = await Supabase.instance.client
          .from('transactions')
          .select('amount')
          .eq('post_id', postId)
          .or('status.eq.paid,status.eq.payout_pending')
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (!mounted) return;
      final amount = (txRes?['amount'] as num?)?.toDouble() ?? 0.0;

      debugPrint('[NAV][OPEN_APPROVAL] postId=$postId amount=$amount');
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ApproveOrDisputeScreen(
          postId: postId,
          postTitle: post['title'] as String? ?? 'Job',
          clientUserId: widget.userId,
          providerNote: completion?['provider_note'] as String?,
          amount: amount,
        ),
      ));
    } catch (e) {
      debugPrint('[NAV][OPEN_APPROVAL][ERROR] _openApprovalFromBell: $e');
      if (mounted) _openMessages();
    }
  }

  /// Navigate to ApplicationsScreen, fetching post data first.
  Future<void> _openApplicationsFromBell({required String postId}) async {
    try {
      final post = await Supabase.instance.client
          .from('posts')
          .select('id, title, author_user_id')
          .eq('id', postId)
          .maybeSingle();

      if (!mounted || post == null) {
        if (mounted) _openMessages();
        return;
      }

      debugPrint('[NAV][OPEN_APPLICATIONS] postId=$postId');
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ApplicationsScreen(
          postId: postId,
          postTitle: post['title'] as String? ?? 'Job',
          authorUserId: post['author_user_id'] as String? ?? widget.userId,
        ),
      ));
    } catch (e) {
      debugPrint('[NAV][OPEN_APPLICATIONS][ERROR] _openApplicationsFromBell: $e');
    }
  }

  /// Find the chat for a given post_id where the current user is a participant.
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
      debugPrint('[NOTIFICATIONS][NAV][ERROR] _findChatByPost: $e');
      return null;
    }
  }

  /// Find the chat for a post_id where otherUserId is a participant.
  Future<String?> _findChatByParticipant({
    required String postId,
    required String otherUserId,
  }) async {
    try {
      final res = await Supabase.instance.client
          .from('chats')
          .select('id')
          .eq('post_id', postId)
          .or('user1.eq.$otherUserId,user2.eq.$otherUserId')
          .maybeSingle();
      return res?['id'] as String?;
    } catch (e) {
      debugPrint('[NOTIFICATIONS][NAV][ERROR] _findChatByParticipant: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.darkBackground : AppTheme.lightBackground;
    final card = isDark ? AppTheme.darkCard : Colors.white;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A2E);
    final textSecondary = isDark ? Colors.white54 : Colors.black54;

    final unread = _notifications.where((n) => !n.read).length;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: textPrimary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Notifications${unread > 0 ? ' ($unread)' : ''}',
          style: TextStyle(
              color: textPrimary, fontWeight: FontWeight.w700, fontSize: 18),
        ),
        actions: [
          if (unread > 0)
            TextButton(
              onPressed: _markAllRead,
              child: Text('Mark all read',
                  style: TextStyle(
                      color: AppTheme.primaryAccent,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ),
        ],
      ),
      body: _buildBody(
        isDark: isDark,
        card: card,
        textPrimary: textPrimary,
        textSecondary: textSecondary,
      ),
    );
  }

  Widget _buildBody({
    required bool isDark,
    required Color card,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline_rounded, color: textSecondary, size: 40),
            const SizedBox(height: 12),
            Text(_error!,
                style: TextStyle(color: textSecondary, fontSize: 14)),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _load,
              child: Text('Retry',
                  style: TextStyle(color: AppTheme.primaryAccent)),
            ),
          ],
        ),
      );
    }

    if (_notifications.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.notifications_none_rounded,
                color: textSecondary, size: 48),
            const SizedBox(height: 12),
            Text('No notifications yet',
                style: TextStyle(
                    color: textSecondary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text("You'll be notified about payments, job updates, and disputes.",
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: textSecondary.withOpacity(0.7), fontSize: 13)),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.primaryAccent,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _notifications.length,
        separatorBuilder: (_, __) => const SizedBox(height: 1),
        itemBuilder: (context, i) {
          final n = _notifications[i];
          return _NotificationTile(
            notification: n,
            card: card,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            onTap: () => _tapNotification(n),
          );
        },
      ),
    );
  }
}

// ─── Tile ─────────────────────────────────────────────────────────────────────

class _NotificationTile extends StatelessWidget {
  final AppNotification notification;
  final Color card;
  final Color textPrimary;
  final Color textSecondary;
  final VoidCallback onTap;

  const _NotificationTile({
    required this.notification,
    required this.card,
    required this.textPrimary,
    required this.textSecondary,
    required this.onTap,
  });

  IconData get _icon {
    switch (notification.type) {
      case 'chat_message': return Icons.chat_bubble_rounded;
      case 'provider_applied': return Icons.person_add_rounded;
      case 'payment_secured': return Icons.lock_rounded;
      case 'provider_selected': return Icons.how_to_reg_rounded;
      case 'completion_requested': return Icons.check_circle_outline_rounded;
      case 'job_approved': return Icons.thumb_up_rounded;
      case 'payout_released': return Icons.payments_rounded;
      case 'dispute_opened':
      case 'dispute_opened_confirm': return Icons.flag_rounded;
      case 'dispute_resolved_release':
      case 'dispute_resolved_refund':
      case 'dispute_resolved_partial': return Icons.gavel_rounded;
      case 'escrow_released': return Icons.account_balance_wallet_rounded;
      default: return Icons.notifications_rounded;
    }
  }

  Color get _iconColor {
    switch (notification.type) {
      case 'chat_message': return AppTheme.primaryAccent;
      case 'provider_applied': return AppTheme.primaryAccent;
      case 'payment_secured':
      case 'payout_released':
      case 'escrow_released': return AppTheme.successGreen;
      case 'dispute_opened':
      case 'dispute_opened_confirm': return Colors.red;
      case 'dispute_resolved_release':
      case 'dispute_resolved_refund':
      case 'dispute_resolved_partial': return AppTheme.warningOrange;
      default: return AppTheme.primaryAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    final unread = !notification.read;

    return InkWell(
      onTap: onTap,
      child: Container(
        color: unread ? _iconColor.withOpacity(0.05) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _iconColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_icon, color: _iconColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          notification.title,
                          style: TextStyle(
                            color: textPrimary,
                            fontWeight: unread
                                ? FontWeight.w700
                                : FontWeight.w500,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      if (unread)
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: _iconColor, shape: BoxShape.circle),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    notification.body,
                    style: TextStyle(
                        color: textSecondary, fontSize: 13, height: 1.4),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatRelativeTime(notification.createdAt),
                    style: TextStyle(
                        color: textSecondary.withOpacity(0.7), fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Badge widget (reusable in nav bar or profile) ───────────────────────────

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
  int _unread = 0;
  RealtimeChannel? _subscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.unsubscribe();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  void _subscribeRealtime() {
    debugPrint('[NOTIFICATIONS][BADGE] Subscribing realtime for userId=${widget.userId}');
    _subscription = Supabase.instance.client
        .channel('notification_badge:${widget.userId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: widget.userId,
          ),
          callback: (_) {
            debugPrint('[NOTIFICATIONS][BADGE] Realtime event → refreshing count');
            _refresh();
          },
        )
        .subscribe((status, [error]) {
          debugPrint('[NOTIFICATIONS][BADGE] subscription status=$status error=$error');
        });
  }

  Future<void> _refresh() async {
    try {
      final count = await NotificationsDb.unreadCount(widget.userId);
      debugPrint('[NOTIFICATIONS][BADGE] unread=$count for userId=${widget.userId}');
      if (mounted) setState(() => _unread = count);
    } catch (e) {
      debugPrint('[NOTIFICATIONS][BADGE][ERROR] $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unread == 0) return widget.child;
    return Badge(
      label: Text(_unread > 99 ? '99+' : '$_unread'),
      backgroundColor: Colors.red,
      child: widget.child,
    );
  }
}
