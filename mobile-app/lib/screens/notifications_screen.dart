import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/time_utils.dart';

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
    if (!n.read) {
      await NotificationsDb.markRead(n.id);
      if (mounted) {
        setState(() {
          _notifications = _notifications
              .map((x) => x.id == n.id
                  ? AppNotification(
                      id: x.id,
                      type: x.type,
                      title: x.title,
                      body: x.body,
                      data: x.data,
                      read: true,
                      createdAt: x.createdAt,
                    )
                  : x)
              .toList();
        });
      }
    }
    // Navigation based on type can be added here in a future iteration.
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
