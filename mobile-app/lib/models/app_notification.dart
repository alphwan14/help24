import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One notification, exactly as the `notifications` table stores it.
@immutable
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
    final rawData = json['data'];
    return AppNotification(
      id: json['id']?.toString() ?? '',
      type: json['type'] as String? ?? '',
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      data: rawData is Map ? Map<String, dynamic>.from(rawData) : const {},
      read: json['read'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
    );
  }

  /// Round-trips through the on-device cache. Deliberately the same key names
  /// as the table, so a cached row and a fetched row parse through the one
  /// [AppNotification.fromJson] and can never drift apart.
  Map<String, dynamic> toCacheMap() => {
        'id': id,
        'type': type,
        'title': title,
        'body': body,
        'data': data,
        'read': read,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  AppNotification copyWith({bool? read}) => AppNotification(
        id: id,
        type: type,
        title: title,
        body: body,
        data: data,
        read: read ?? this.read,
        createdAt: createdAt,
      );

  NotificationKind get kind => NotificationKind.of(type);

  /// The listing this notification is about, when it names one. Used for the
  /// subject line and as half of the grouping key.
  String? get postId => _string('post_id');
  String? get chatId => _string('chat_id');
  String? get disputeId => _string('dispute_id');
  String? get transactionId => _string('transaction_id');

  /// The other person, when the payload names one. `provider_applied` carries
  /// the applicant; nothing else currently carries an actor id, so this is
  /// null far more often than not — and every surface that reads it must
  /// render perfectly well without it.
  String? get actorUserId =>
      _string('applicant_user_id') ?? _string('provider_id') ?? _string('actor_user_id');

  String? _string(String key) {
    final value = data[key];
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// What a group of these is keyed on: same kind, same subject.
  ///
  /// Three applications on one job collapse into one row; three applications
  /// across three jobs stay three rows, because they need three different
  /// decisions from the user.
  String get groupKey => '$type::${postId ?? disputeId ?? chatId ?? id}';
}

/// The sections of the notification centre.
///
/// These are the user's mental model of the marketplace, not the database's:
/// somebody scanning the register is asking "is there money involved", "is
/// somebody waiting on me", "has something gone wrong" — never "which service
/// emitted this".
enum NotificationCategory {
  applications('Applications'),
  jobs('Jobs'),
  payments('Payments'),
  disputes('Disputes'),
  reviews('Reviews'),
  provider('Provider'),
  messages('Messages'),
  promotions('Promotions'),
  system('System'),
  support('Support');

  const NotificationCategory(this.label);

  final String label;
}

/// How much of the user's attention a notification has earned.
///
/// WHY THIS IS NOT JUST A SORT KEY
/// -------------------------------
/// On Help24 the range runs from "your badge changed" to "money you are owed is
/// in dispute". Treating those as equal — which a pure timeline does — means the
/// important one is one scroll away from being missed, and the cost of missing
/// it is somebody's livelihood rather than a lost like.
///
/// Priority earns [critical] and [high] items a place in a pinned block ABOVE
/// the timeline, and only while they are UNREAD. Once read they fall back into
/// chronological history, because a resolved dispute from last week must not
/// outrank this morning's application. That is what keeps the register both
/// urgent and honest: importance decides what surfaces, recency decides
/// everything else, and nothing re-sorts under the reader.
enum NotificationPriority {
  /// Money and disputes. Real funds have moved, or are at risk.
  critical,

  /// Somebody is waiting on this user to act.
  high,

  /// Worth knowing, no action required.
  normal,

  /// Bookkeeping. True, unremarkable, and near the bottom.
  low;

  /// Ascending sort weight — lower sorts first.
  int get weight => index;

  bool get isPinnable =>
      this == NotificationPriority.critical || this == NotificationPriority.high;
}

/// Everything the app knows about a notification type, in ONE place.
///
/// THE DUPLICATION THIS RETIRES
/// ----------------------------
/// The taxonomy used to live in three files that were maintained separately and
/// agreed in none: the backend's canonical `NotificationType` union (22 types),
/// the notification tile's icon `switch` (14), and the tap router's `switch`
/// (16). The arithmetic is the bug: seven types — `review_received`,
/// `job_cancelled` and all four `promotion_*` among them — rendered as an
/// anonymous grey bell AND did nothing at all when tapped. A user who was told
/// their campaign had been rejected could tap it forever.
///
/// Sectioning, ordering, the icon, the tone, the action label and the
/// destination are now all derived from here, so a type can no longer be
/// half-supported: adding one is a single entry, and forgetting to add one
/// degrades to [unknown], which still renders and still goes somewhere sensible.
@immutable
class NotificationKind {
  /// The wire value stored in `notifications.type`.
  final String type;
  final NotificationCategory category;
  final NotificationPriority priority;
  final IconData icon;

  /// Which of the four tones this reads in. Colour is resolved against the
  /// theme at build time rather than stored, so dark mode is not a second
  /// table to keep in sync.
  final NotificationTone tone;

  /// The label on the tile's action button, when there is a real next step.
  /// Null means the notification is informational — and an informational row
  /// showing a button is how an app teaches people that its buttons are
  /// decoration.
  final String? action;

  const NotificationKind._({
    required this.type,
    required this.category,
    required this.priority,
    required this.icon,
    required this.tone,
    this.action,
  });

  /// The fallback for a type this build has never heard of.
  ///
  /// A forward-compatibility guarantee, not a defensive habit: it is what makes
  /// it safe for the backend to add a notification type before the client that
  /// understands it has shipped. The row renders with its server-written title
  /// and body — which are already human — and taps through to whatever context
  /// its payload names.
  static const NotificationKind unknown = NotificationKind._(
    type: '',
    category: NotificationCategory.system,
    priority: NotificationPriority.normal,
    icon: Icons.notifications_rounded,
    tone: NotificationTone.neutral,
  );

  static NotificationKind of(String type) => _byType[type] ?? unknown;

  /// Every type this build understands. Ordered by category for reading.
  static const List<NotificationKind> all = [
    // ── Applications ────────────────────────────────────────────────────────
    NotificationKind._(
      type: 'provider_applied',
      category: NotificationCategory.applications,
      priority: NotificationPriority.high,
      icon: Icons.person_add_alt_1_rounded,
      tone: NotificationTone.accent,
      action: 'Review applicants',
    ),
    NotificationKind._(
      type: 'application_withdrawn',
      category: NotificationCategory.applications,
      priority: NotificationPriority.normal,
      icon: Icons.person_remove_alt_1_rounded,
      tone: NotificationTone.neutral,
      action: 'View applicants',
    ),

    // ── Jobs ────────────────────────────────────────────────────────────────
    NotificationKind._(
      type: 'provider_selected',
      category: NotificationCategory.jobs,
      priority: NotificationPriority.high,
      icon: Icons.how_to_reg_rounded,
      tone: NotificationTone.positive,
      action: 'Open job chat',
    ),
    NotificationKind._(
      type: 'completion_requested',
      category: NotificationCategory.jobs,
      priority: NotificationPriority.high,
      icon: Icons.fact_check_rounded,
      tone: NotificationTone.accent,
      action: 'Review the work',
    ),
    NotificationKind._(
      type: 'job_approved',
      category: NotificationCategory.jobs,
      priority: NotificationPriority.normal,
      icon: Icons.thumb_up_rounded,
      tone: NotificationTone.positive,
      action: 'View job',
    ),
    NotificationKind._(
      type: 'job_cancelled',
      category: NotificationCategory.jobs,
      priority: NotificationPriority.high,
      icon: Icons.cancel_rounded,
      tone: NotificationTone.warning,
      action: 'View job',
    ),

    // ── Payments ────────────────────────────────────────────────────────────
    // Every one of these is critical. Money has moved, or is about to.
    NotificationKind._(
      type: 'payment_secured',
      category: NotificationCategory.payments,
      priority: NotificationPriority.critical,
      icon: Icons.lock_rounded,
      tone: NotificationTone.positive,
      action: 'View job',
    ),
    NotificationKind._(
      type: 'payout_released',
      category: NotificationCategory.payments,
      priority: NotificationPriority.critical,
      icon: Icons.payments_rounded,
      tone: NotificationTone.positive,
      action: 'View payout',
    ),
    NotificationKind._(
      type: 'escrow_released',
      category: NotificationCategory.payments,
      priority: NotificationPriority.critical,
      icon: Icons.account_balance_wallet_rounded,
      tone: NotificationTone.positive,
      action: 'View job',
    ),

    // ── Disputes ────────────────────────────────────────────────────────────
    NotificationKind._(
      type: 'dispute_opened',
      category: NotificationCategory.disputes,
      priority: NotificationPriority.critical,
      icon: Icons.flag_rounded,
      tone: NotificationTone.critical,
      action: 'Open dispute',
    ),
    NotificationKind._(
      type: 'dispute_opened_confirm',
      category: NotificationCategory.disputes,
      priority: NotificationPriority.critical,
      icon: Icons.flag_rounded,
      tone: NotificationTone.critical,
      action: 'Open dispute',
    ),
    NotificationKind._(
      type: 'dispute_evidence_requested',
      category: NotificationCategory.disputes,
      priority: NotificationPriority.critical,
      icon: Icons.upload_file_rounded,
      tone: NotificationTone.critical,
      action: 'Upload evidence',
    ),
    NotificationKind._(
      type: 'dispute_evidence_uploaded',
      category: NotificationCategory.disputes,
      priority: NotificationPriority.normal,
      icon: Icons.attach_file_rounded,
      tone: NotificationTone.warning,
      action: 'Open thread',
    ),
    NotificationKind._(
      type: 'dispute_message',
      category: NotificationCategory.disputes,
      priority: NotificationPriority.high,
      icon: Icons.forum_rounded,
      tone: NotificationTone.warning,
      action: 'Open thread',
    ),
    NotificationKind._(
      type: 'dispute_resolved_release',
      category: NotificationCategory.disputes,
      priority: NotificationPriority.critical,
      icon: Icons.gavel_rounded,
      tone: NotificationTone.positive,
      action: 'View resolution',
    ),
    NotificationKind._(
      type: 'dispute_resolved_refund',
      category: NotificationCategory.disputes,
      priority: NotificationPriority.critical,
      icon: Icons.gavel_rounded,
      tone: NotificationTone.warning,
      action: 'View resolution',
    ),
    NotificationKind._(
      type: 'dispute_resolved_partial',
      category: NotificationCategory.disputes,
      priority: NotificationPriority.critical,
      icon: Icons.gavel_rounded,
      tone: NotificationTone.warning,
      action: 'View resolution',
    ),

    // ── Reviews ─────────────────────────────────────────────────────────────
    NotificationKind._(
      type: 'review_requested',
      category: NotificationCategory.reviews,
      priority: NotificationPriority.high,
      icon: Icons.star_outline_rounded,
      tone: NotificationTone.accent,
      action: 'Leave a review',
    ),
    NotificationKind._(
      type: 'review_received',
      category: NotificationCategory.reviews,
      priority: NotificationPriority.normal,
      icon: Icons.star_rounded,
      tone: NotificationTone.positive,
      action: 'View review',
    ),

    // ── Provider ────────────────────────────────────────────────────────────
    NotificationKind._(
      type: 'verification_approved',
      category: NotificationCategory.provider,
      priority: NotificationPriority.normal,
      icon: Icons.verified_rounded,
      tone: NotificationTone.positive,
      action: 'View profile',
    ),
    NotificationKind._(
      type: 'badge_earned',
      category: NotificationCategory.provider,
      priority: NotificationPriority.low,
      icon: Icons.workspace_premium_rounded,
      tone: NotificationTone.neutral,
      action: 'View profile',
    ),
    NotificationKind._(
      type: 'profile_updated',
      category: NotificationCategory.provider,
      priority: NotificationPriority.low,
      icon: Icons.manage_accounts_rounded,
      tone: NotificationTone.neutral,
    ),

    // ── Messages ────────────────────────────────────────────────────────────
    // Present so the kind is total over the backend's type union. Chat is
    // surfaced in the Messages tab and is filtered out of the bell entirely —
    // two inboxes for one conversation is how unread counts start lying.
    NotificationKind._(
      type: 'chat_message',
      category: NotificationCategory.messages,
      priority: NotificationPriority.normal,
      icon: Icons.chat_bubble_rounded,
      tone: NotificationTone.accent,
      action: 'Open chat',
    ),

    // ── Promotions ──────────────────────────────────────────────────────────
    NotificationKind._(
      type: 'promotion_payment_received',
      category: NotificationCategory.promotions,
      priority: NotificationPriority.normal,
      icon: Icons.receipt_long_rounded,
      tone: NotificationTone.positive,
      action: 'View campaign',
    ),
    NotificationKind._(
      type: 'promotion_live',
      category: NotificationCategory.promotions,
      priority: NotificationPriority.normal,
      icon: Icons.campaign_rounded,
      tone: NotificationTone.positive,
      action: 'View campaign',
    ),
    NotificationKind._(
      type: 'promotion_rejected',
      category: NotificationCategory.promotions,
      priority: NotificationPriority.high,
      icon: Icons.block_rounded,
      tone: NotificationTone.warning,
      action: 'View campaign',
    ),
    NotificationKind._(
      type: 'promotion_completed',
      category: NotificationCategory.promotions,
      priority: NotificationPriority.low,
      icon: Icons.done_all_rounded,
      tone: NotificationTone.neutral,
      action: 'View campaign',
    ),

    // ── System / Support ────────────────────────────────────────────────────
    NotificationKind._(
      type: 'security_alert',
      category: NotificationCategory.system,
      priority: NotificationPriority.critical,
      icon: Icons.shield_rounded,
      tone: NotificationTone.critical,
    ),
    NotificationKind._(
      type: 'maintenance',
      category: NotificationCategory.system,
      priority: NotificationPriority.low,
      icon: Icons.build_rounded,
      tone: NotificationTone.neutral,
    ),
    NotificationKind._(
      type: 'version_update',
      category: NotificationCategory.system,
      priority: NotificationPriority.low,
      icon: Icons.system_update_rounded,
      tone: NotificationTone.neutral,
    ),
    NotificationKind._(
      type: 'support_reply',
      category: NotificationCategory.support,
      priority: NotificationPriority.high,
      icon: Icons.support_agent_rounded,
      tone: NotificationTone.accent,
      action: 'Open ticket',
    ),
    NotificationKind._(
      type: 'support_ticket_updated',
      category: NotificationCategory.support,
      priority: NotificationPriority.normal,
      icon: Icons.confirmation_number_rounded,
      tone: NotificationTone.neutral,
      action: 'Open ticket',
    ),
  ];

  static final Map<String, NotificationKind> _byType = {
    for (final kind in all) kind.type: kind,
  };
}

/// The four tones a notification can read in. Resolved against the theme so
/// there is one colour decision per tone rather than one per type per mode.
enum NotificationTone {
  /// Money arrived, work was approved, a dispute went your way.
  positive,

  /// Something needs doing, or is happening now.
  accent,

  /// Something went against the user but is not an emergency.
  warning,

  /// A dispute, or a security event. The loudest the register gets.
  critical,

  /// True and unremarkable.
  neutral;

  Color color(bool isDark) => switch (this) {
        NotificationTone.positive => AppTheme.successGreen,
        NotificationTone.accent => AppTheme.primaryAccent,
        NotificationTone.warning => AppTheme.warningOrange,
        NotificationTone.critical => AppTheme.errorRed,
        NotificationTone.neutral =>
          isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
      };
}
