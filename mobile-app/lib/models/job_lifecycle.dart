/// Parsed response of GET /jobs/:postId/lifecycle — the single source of truth
/// for the Job Lifecycle Detail screen. Mirrors the backend aggregate; the mobile
/// app derives display stages from these raw statuses but never stores lifecycle state.
class JobLifecycle {
  final LifecyclePost post;
  final String viewerRole; // 'client' | 'provider'
  final LifecyclePayment? payment;
  final LifecycleEscrow? escrow;
  final LifecycleCompletion? completion;
  final LifecycleDispute? dispute;
  final List<TimelineEvent> timeline;

  const JobLifecycle({
    required this.post,
    required this.viewerRole,
    required this.payment,
    required this.escrow,
    required this.completion,
    required this.dispute,
    required this.timeline,
  });

  bool get isClient => viewerRole == 'client';

  factory JobLifecycle.fromJson(Map<String, dynamic> j) {
    return JobLifecycle(
      post: LifecyclePost.fromJson(j['post'] as Map<String, dynamic>),
      viewerRole: j['viewer_role'] as String? ?? 'client',
      payment: j['payment'] == null ? null : LifecyclePayment.fromJson(j['payment'] as Map<String, dynamic>),
      escrow: j['escrow'] == null ? null : LifecycleEscrow.fromJson(j['escrow'] as Map<String, dynamic>),
      completion: j['completion'] == null ? null : LifecycleCompletion.fromJson(j['completion'] as Map<String, dynamic>),
      dispute: j['dispute'] == null ? null : LifecycleDispute.fromJson(j['dispute'] as Map<String, dynamic>),
      timeline: ((j['timeline'] as List<dynamic>?) ?? [])
          .map((e) => TimelineEvent.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class LifecyclePost {
  final String id;
  final String title;
  final double price;
  final String status; // open | assigned | completed | disputed | cancelled
  final String authorUserId;
  final String? selectedProviderId;

  const LifecyclePost({
    required this.id,
    required this.title,
    required this.price,
    required this.status,
    required this.authorUserId,
    required this.selectedProviderId,
  });

  factory LifecyclePost.fromJson(Map<String, dynamic> j) => LifecyclePost(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Job',
        price: (j['price'] as num?)?.toDouble() ?? 0,
        status: j['status'] as String? ?? 'open',
        authorUserId: j['author_user_id'] as String? ?? '',
        selectedProviderId: j['selected_provider_id'] as String?,
      );
}

class LifecyclePayment {
  final String transactionId;
  final String status; // pending | paid | payout_pending | released | disputed | refunded | failed
  final double amount;
  final double? totalPaid;
  final String? mpesaReceipt;

  const LifecyclePayment({
    required this.transactionId,
    required this.status,
    required this.amount,
    required this.totalPaid,
    required this.mpesaReceipt,
  });

  factory LifecyclePayment.fromJson(Map<String, dynamic> j) => LifecyclePayment(
        transactionId: j['transaction_id'] as String? ?? '',
        status: j['status'] as String? ?? 'pending',
        amount: (j['amount'] as num?)?.toDouble() ?? 0,
        totalPaid: (j['total_paid'] as num?)?.toDouble(),
        mpesaReceipt: j['mpesa_receipt'] as String?,
      );
}

class LifecycleEscrow {
  final String status; // locked | payout_pending | released | disputed | refunded
  final String? releasedAt;

  const LifecycleEscrow({required this.status, required this.releasedAt});

  factory LifecycleEscrow.fromJson(Map<String, dynamic> j) => LifecycleEscrow(
        status: j['status'] as String? ?? 'locked',
        releasedAt: j['released_at'] as String?,
      );
}

class LifecycleCompletion {
  final String id;
  final String status; // pending_approval | approved | disputed
  final String? providerNote;
  final String? createdAt;
  final String? reviewedAt;

  const LifecycleCompletion({
    required this.id,
    required this.status,
    required this.providerNote,
    required this.createdAt,
    required this.reviewedAt,
  });

  factory LifecycleCompletion.fromJson(Map<String, dynamic> j) => LifecycleCompletion(
        id: j['id'] as String? ?? '',
        status: j['status'] as String? ?? 'pending_approval',
        providerNote: j['provider_note'] as String?,
        createdAt: j['created_at'] as String?,
        reviewedAt: j['reviewed_at'] as String?,
      );
}

class LifecycleDispute {
  final String id;
  final String status; // open | reviewing | awaiting_evidence | escalated | resolved | resolved_*
  final String? priority;
  final String? reason;
  final String? raisedByRole;
  final double? providerAmount;
  final double? buyerRefund;
  final String? createdAt;
  final String? resolvedAt;
  final List<LifecycleDecision> decisions;

  const LifecycleDispute({
    required this.id,
    required this.status,
    required this.priority,
    required this.reason,
    required this.raisedByRole,
    required this.providerAmount,
    required this.buyerRefund,
    required this.createdAt,
    required this.resolvedAt,
    required this.decisions,
  });

  /// The ruling that closed the case, if resolved.
  LifecycleDecision? get finalDecision => decisions.isEmpty ? null : decisions.last;

  factory LifecycleDispute.fromJson(Map<String, dynamic> j) => LifecycleDispute(
        id: j['id'] as String? ?? '',
        status: j['status'] as String? ?? 'open',
        priority: j['priority'] as String?,
        reason: j['reason'] as String?,
        raisedByRole: j['raised_by_role'] as String?,
        providerAmount: (j['provider_amount'] as num?)?.toDouble(),
        buyerRefund: (j['buyer_refund'] as num?)?.toDouble(),
        createdAt: j['created_at'] as String?,
        resolvedAt: j['resolved_at'] as String?,
        decisions: ((j['decisions'] as List<dynamic>?) ?? [])
            .map((e) => LifecycleDecision.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class LifecycleDecision {
  final String decisionType; // FULL_RELEASE | FULL_REFUND | PARTIAL_SPLIT | ESCALATE
  final String? reasoning;
  final double? providerAmount;
  final double? clientRefundAmount;
  final bool decidedBySystem;
  final String? createdAt;

  const LifecycleDecision({
    required this.decisionType,
    required this.reasoning,
    required this.providerAmount,
    required this.clientRefundAmount,
    required this.decidedBySystem,
    required this.createdAt,
  });

  factory LifecycleDecision.fromJson(Map<String, dynamic> j) => LifecycleDecision(
        decisionType: j['decision_type'] as String? ?? '',
        reasoning: j['reasoning'] as String?,
        providerAmount: (j['provider_amount'] as num?)?.toDouble(),
        clientRefundAmount: (j['client_refund_amount'] as num?)?.toDouble(),
        decidedBySystem: j['decided_by_system'] as bool? ?? false,
        createdAt: j['created_at'] as String?,
      );
}

class TimelineEvent {
  final String type;
  final String label;
  final String at; // ISO timestamp

  const TimelineEvent({required this.type, required this.label, required this.at});

  factory TimelineEvent.fromJson(Map<String, dynamic> j) => TimelineEvent(
        type: j['type'] as String? ?? '',
        label: j['label'] as String? ?? '',
        at: j['at'] as String? ?? '',
      );
}
