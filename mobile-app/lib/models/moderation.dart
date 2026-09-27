import 'package:flutter/foundation.dart';

/// Trust & Safety vocabulary shared by the report flow and the account-status
/// surfaces.
///
/// THE TAXONOMY IS NOT OWNED HERE
/// ------------------------------
/// The categories, and which of them make sense for which kind of target, are
/// defined once in `supabase/tests/trust-safety/report_taxonomy.json` and
/// enforced by the database (`moderation_report_categories`). The backend and
/// this file mirror it, and `test/moderation_taxonomy_test.dart` fails the
/// build if they drift — a category the database refuses would surface as a
/// report that cannot be sent.

/// What is being reported. The wire value is what the API and the database
/// store in `user_reports.target_type`.
enum ReportTargetType {
  user('user'),
  post('post'),
  application('application'),
  message('message');

  const ReportTargetType(this.wire);
  final String wire;
}

/// Why. Labels are the words a person picks from, not the database's.
enum ReportCategory {
  scamOrFraud('scam_or_fraud', 'Scam or fraud'),
  suspiciousActivity('suspicious_activity', 'Suspicious activity'),
  illegalActivity('illegal_activity', 'Illegal activity'),
  harassment('harassment', 'Harassment or abusive behaviour'),
  threats('threats', 'Threats or intimidation'),
  inappropriateContent('inappropriate_content', 'Inappropriate content'),
  impersonation('impersonation', 'Fake identity or impersonation'),
  misleadingListing('misleading_listing', 'Misleading service or request'),
  paymentIssue('payment_issue', 'Payment-related issue'),
  spam('spam', 'Spam'),
  unsafeBehavior('unsafe_behavior', 'Unsafe behaviour'),
  other('other', 'Other');

  const ReportCategory(this.wire, this.label);

  final String wire;
  final String label;

  /// The categories offered for [target], most likely first. Mirrors
  /// `by_target` in report_taxonomy.json exactly — order included, because
  /// the order is the product decision about what to put under the thumb.
  static List<ReportCategory> forTarget(ReportTargetType target) => switch (target) {
        ReportTargetType.user => const [
            scamOrFraud, suspiciousActivity, harassment, threats, impersonation,
            inappropriateContent, unsafeBehavior, paymentIssue, illegalActivity,
            spam, other,
          ],
        ReportTargetType.post => const [
            scamOrFraud, misleadingListing, suspiciousActivity, illegalActivity,
            inappropriateContent, impersonation, paymentIssue, unsafeBehavior,
            spam, other,
          ],
        ReportTargetType.application => const [
            scamOrFraud, suspiciousActivity, misleadingListing, harassment,
            inappropriateContent, impersonation, paymentIssue, unsafeBehavior,
            spam, other,
          ],
        ReportTargetType.message => const [
            harassment, threats, scamOrFraud, paymentIssue, inappropriateContent,
            suspiciousActivity, unsafeBehavior, illegalActivity, impersonation,
            spam, other,
          ],
      };
}

/// Something that can be reported, with the context the server needs to find
/// it. The server derives who is being reported from [id]; [subjectName] is
/// only for the sheet's own copy and is never sent.
@immutable
class ReportTarget {
  const ReportTarget._({
    required this.type,
    required this.id,
    required this.subjectName,
    this.chatId,
    this.postId,
  });

  /// A person, optionally from inside a conversation or a listing they are
  /// part of — context the server keeps only when it checks out.
  factory ReportTarget.user({
    required String userId,
    required String name,
    String? chatId,
    String? postId,
  }) =>
      ReportTarget._(
        type: ReportTargetType.user,
        id: userId,
        subjectName: name,
        chatId: chatId,
        postId: postId,
      );

  /// A Request, Offer or job listing.
  factory ReportTarget.post({required String postId, required String title}) =>
      ReportTarget._(type: ReportTargetType.post, id: postId, subjectName: title);

  /// An application to the reporter's own listing.
  factory ReportTarget.application({required String applicationId, required String applicantName}) =>
      ReportTarget._(type: ReportTargetType.application, id: applicationId, subjectName: applicantName);

  /// One message the reporter received.
  factory ReportTarget.message({required String messageId, required String senderName}) =>
      ReportTarget._(type: ReportTargetType.message, id: messageId, subjectName: senderName);

  final ReportTargetType type;
  final String id;
  final String subjectName;
  final String? chatId;
  final String? postId;

  List<ReportCategory> get categories => ReportCategory.forTarget(type);

  /// The sheet's subtitle: what, exactly, is being reported.
  String get description => switch (type) {
        ReportTargetType.user => 'Reporting $subjectName',
        ReportTargetType.post => 'Reporting the listing "$subjectName"',
        ReportTargetType.application => 'Reporting the application from $subjectName',
        ReportTargetType.message => 'Reporting a message from $subjectName',
      };
}

/// What an account may do. Wire values match `moderation_capabilities()`.
class Capability {
  Capability._();

  static const String post = 'post';
  static const String apply = 'apply';
  static const String hire = 'hire';
  static const String pay = 'pay';
  static const String message = 'message';
  static const String promote = 'promote';
  static const String review = 'review';
  static const String complete = 'complete';
  static const String payoutConfig = 'payout_config';

  static const List<String> all = [post, apply, hire, pay, message, promote, review, complete, payoutConfig];
}

enum AccountStanding {
  active,
  restricted,
  suspended,
  banned,

  /// The status could not be read. Never treated as a restriction: the server
  /// enforces, and a failed read must not lock a person out of their account.
  unknown;

  static AccountStanding parse(Object? raw) => switch (raw) {
        'active' => AccountStanding.active,
        'restricted' => AccountStanding.restricted,
        'suspended' => AccountStanding.suspended,
        'banned' => AccountStanding.banned,
        _ => AccountStanding.unknown,
      };
}

enum RestrictionKind {
  suspension,
  ban,
  messaging,
  marketplace;

  static RestrictionKind? parse(Object? raw) => switch (raw) {
        'suspension' => RestrictionKind.suspension,
        'ban' => RestrictionKind.ban,
        'messaging' => RestrictionKind.messaging,
        'marketplace' => RestrictionKind.marketplace,
        _ => null,
      };

  String get title => switch (this) {
        RestrictionKind.suspension => 'Account suspended',
        RestrictionKind.ban => 'Account banned',
        RestrictionKind.messaging => 'Messaging restricted',
        RestrictionKind.marketplace => 'Marketplace activity restricted',
      };

  /// What the restriction stops, in plain words.
  String get effect => switch (this) {
        RestrictionKind.suspension =>
          "You can't post, apply, hire, pay, send messages or leave reviews until it ends.",
        RestrictionKind.ban =>
          "You can't post, apply, hire, pay, send messages or leave reviews on Help24.",
        RestrictionKind.messaging => "You can't start conversations or send messages.",
        RestrictionKind.marketplace => "You can't post, apply, hire, pay or promote listings.",
      };
}

/// One restriction in force, as `my_account_status()` returns it: the kind,
/// the reason an admin wrote FOR this person, when it ends, and a reference
/// to quote to support. Nothing else — no admin, no internal note, no reporter.
@immutable
class AccountRestriction {
  const AccountRestriction({
    required this.id,
    required this.kind,
    required this.reason,
    required this.startsAt,
    required this.endsAt,
    required this.reference,
  });

  final String id;
  final RestrictionKind kind;
  final String reason;
  final DateTime? startsAt;

  /// Null for a ban or an open-ended partial restriction.
  final DateTime? endsAt;
  final String reference;

  static AccountRestriction? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = RestrictionKind.parse(raw['kind']);
    final id = raw['id']?.toString() ?? '';
    if (kind == null || id.isEmpty) return null;
    return AccountRestriction(
      id: id,
      kind: kind,
      reason: raw['reason']?.toString() ?? '',
      startsAt: _date(raw['starts_at']),
      endsAt: _date(raw['ends_at']),
      reference: raw['reference']?.toString() ?? '',
    );
  }
}

@immutable
class AccountWarning {
  const AccountWarning({required this.id, required this.reason, required this.createdAt, required this.reference});

  final String id;
  final String reason;
  final DateTime? createdAt;
  final String reference;

  static AccountWarning? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return AccountWarning(
      id: id,
      reason: raw['reason']?.toString() ?? '',
      createdAt: _date(raw['created_at']),
      reference: raw['reference']?.toString() ?? '',
    );
  }
}

/// The signed-in person's own standing.
@immutable
class AccountStatus {
  const AccountStatus({
    required this.standing,
    required this.restrictions,
    required this.deniedCapabilities,
    required this.warnings,
    required this.serverTime,
  });

  static const AccountStatus unknown = AccountStatus(
    standing: AccountStanding.unknown,
    restrictions: [],
    deniedCapabilities: {},
    warnings: [],
    serverTime: null,
  );

  final AccountStanding standing;
  final List<AccountRestriction> restrictions;
  final Set<String> deniedCapabilities;
  final List<AccountWarning> warnings;

  /// The database's clock when this was read. Countdowns are computed against
  /// it (offset by local elapsed time), not against a phone clock that may be
  /// hours wrong.
  final DateTime? serverTime;

  factory AccountStatus.fromJson(Object? raw) {
    if (raw is! Map) return unknown;
    final restrictions = <AccountRestriction>[
      for (final r in (raw['restrictions'] is List ? raw['restrictions'] as List : const []))
        if (AccountRestriction.fromJson(r) case final parsed?) parsed,
    ];
    final warnings = <AccountWarning>[
      for (final w in (raw['warnings'] is List ? raw['warnings'] as List : const []))
        if (AccountWarning.fromJson(w) case final parsed?) parsed,
    ];
    final denied = <String>{
      for (final c in (raw['denied_capabilities'] is List ? raw['denied_capabilities'] as List : const []))
        if (c is String && c.isNotEmpty) c,
    };
    return AccountStatus(
      standing: AccountStanding.parse(raw['status']),
      restrictions: restrictions,
      deniedCapabilities: denied,
      warnings: warnings,
      serverTime: _date(raw['server_time']),
    );
  }

  bool get isKnown => standing != AccountStanding.unknown;

  /// True only when the server said so. An unknown status allows everything —
  /// the server is the enforcement, this is the explanation.
  bool denies(String capability) => deniedCapabilities.contains(capability);

  bool get hasRestriction => restrictions.isNotEmpty;

  /// The restriction that best explains [capability] being denied: a ban over
  /// a suspension over the partial one that names it.
  AccountRestriction? restrictionFor(String capability) {
    if (!denies(capability)) return null;
    AccountRestriction? pick(RestrictionKind k) {
      for (final r in restrictions) {
        if (r.kind == k) return r;
      }
      return null;
    }

    return pick(RestrictionKind.ban) ??
        pick(RestrictionKind.suspension) ??
        (capability == Capability.message ? pick(RestrictionKind.messaging) : pick(RestrictionKind.marketplace)) ??
        (restrictions.isEmpty ? null : restrictions.first);
  }

  /// The one restriction to headline: the most severe in force.
  AccountRestriction? get primary {
    for (final k in const [RestrictionKind.ban, RestrictionKind.suspension, RestrictionKind.marketplace, RestrictionKind.messaging]) {
      for (final r in restrictions) {
        if (r.kind == k) return r;
      }
    }
    return null;
  }
}

DateTime? _date(Object? raw) => raw is String ? DateTime.tryParse(raw)?.toLocal() : null;
