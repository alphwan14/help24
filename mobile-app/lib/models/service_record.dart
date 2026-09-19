/// Parsed responses of the Service Records endpoints:
///   GET /jobs/history?user_id=&role=      → [ServiceHistory]
///   GET /jobs/:postId/receipt?user_id=    → [ServiceReceipt] | [ReceiptUnavailable]
///
/// These mirror the backend aggregate. As with [JobLifecycle], the app derives
/// nothing about money here — `settlementState` and `status` arrive already
/// decided by deriveSettlementState() on the server, which is the ONE money
/// state machine. Re-deriving either on the device would fork it.
library;

/// One page of a user's service records, from one side of the deal.
class ServiceHistory {
  final List<ServiceRecord> records;

  /// Jobs whose completion was APPROVED. This counts finished work, not
  /// settled money — a payout still in flight does not un-do the job.
  final int totalCompleted;

  /// Agreed value of that completed work. Deliberately not "earnings" and not
  /// a balance: it says nothing about what has actually been paid out.
  final double completedValue;

  final bool hasMore;

  const ServiceHistory({
    required this.records,
    required this.totalCompleted,
    required this.completedValue,
    required this.hasMore,
  });

  bool get isEmpty => records.isEmpty;

  factory ServiceHistory.fromJson(Map<String, dynamic> j) => ServiceHistory(
        records: ((j['records'] as List<dynamic>?) ?? const [])
            .map((e) => ServiceRecord.fromJson(e as Map<String, dynamic>))
            .toList(),
        totalCompleted: (j['total_completed'] as num?)?.toInt() ?? 0,
        completedValue: (j['completed_value'] as num?)?.toDouble() ?? 0,
        hasMore: j['has_more'] as bool? ?? false,
      );
}

/// A single row in Service History. Opens into the existing Job Lifecycle
/// screen — the permanent record of that service — by `postId`.
class ServiceRecord {
  final String postId;
  final String title;
  final String? category;
  final String? location;

  /// open | assigned | completed | disputed | cancelled
  final String postStatus;

  /// The post was archived (removed from the feed). The service record itself
  /// is permanent, so the row stays and says so.
  final bool archived;

  /// 'client' (this is a service I bought) | 'provider' (work I did)
  final String viewerRole;

  final String? counterpartyId;
  final String? counterpartyName;

  /// Charged amount, or the agreed post price when no payment exists yet.
  final double? amount;
  final double? totalPaid;
  final String? paymentMethod; // mpesa | airtel_money — null before any payment

  /// The canonical settlement state and its human label, straight from the
  /// backend. See settlement-state.ts for the full vocabulary.
  final String settlementState;
  final String settlementLabel;
  final bool attentionRequired;

  /// Advisory: the receipt endpoint re-checks before issuing one.
  final bool receiptAvailable;

  final DateTime? createdAt;
  final DateTime? completedAt;
  final DateTime? settledAt;

  const ServiceRecord({
    required this.postId,
    required this.title,
    required this.category,
    required this.location,
    required this.postStatus,
    required this.archived,
    required this.viewerRole,
    required this.counterpartyId,
    required this.counterpartyName,
    required this.amount,
    required this.totalPaid,
    required this.paymentMethod,
    required this.settlementState,
    required this.settlementLabel,
    required this.attentionRequired,
    required this.receiptAvailable,
    required this.createdAt,
    required this.completedAt,
    required this.settledAt,
  });

  bool get isClient => viewerRole == 'client';

  /// The work is finished — an approved completion, regardless of whether the
  /// money has finished moving.
  bool get isCompletedWork => completedAt != null;

  factory ServiceRecord.fromJson(Map<String, dynamic> j) {
    final party = (j['counterparty'] as Map<String, dynamic>?) ?? const {};
    final name = party['name'] as String?;
    return ServiceRecord(
      postId: j['post_id'] as String? ?? '',
      title: j['title'] as String? ?? 'Service',
      category: j['category'] as String?,
      location: j['location'] as String?,
      postStatus: j['post_status'] as String? ?? 'open',
      archived: j['archived'] as bool? ?? false,
      viewerRole: j['viewer_role'] as String? ?? 'client',
      counterpartyId: party['user_id'] as String?,
      counterpartyName: (name != null && name.trim().isNotEmpty) ? name : null,
      amount: (j['amount'] as num?)?.toDouble(),
      totalPaid: (j['total_paid'] as num?)?.toDouble(),
      paymentMethod: j['payment_method'] as String?,
      settlementState: j['settlement_state'] as String? ?? 'no_payment',
      settlementLabel: j['settlement_label'] as String? ?? '',
      attentionRequired: j['attention_required'] as bool? ?? false,
      receiptAvailable: j['receipt_available'] as bool? ?? false,
      createdAt: _date(j['created_at']),
      completedAt: _date(j['completed_at']),
      settledAt: _date(j['settled_at']),
    );
  }
}

/// The result of asking for a receipt: either a document, or an honest reason
/// there is not one yet. A payment still in flight produces the latter — never
/// a receipt number, because a number issued against a payment that may still
/// fail is a fabricated financial record.
sealed class ReceiptResult {
  const ReceiptResult();

  factory ReceiptResult.fromJson(Map<String, dynamic> j) {
    if (j['available'] == true) return ServiceReceipt.fromJson(j);
    return ReceiptUnavailable(
      reason: j['reason'] as String? ?? 'unavailable',
      message: j['message'] as String? ?? 'A receipt is not available for this service yet.',
    );
  }
}

class ReceiptUnavailable extends ReceiptResult {
  /// no_payment | payment_pending | payment_failed
  final String reason;
  final String message;

  const ReceiptUnavailable({required this.reason, required this.message});

  bool get isPending => reason == 'payment_pending';
}

/// The Help24 platform receipt. Distinct from, and referencing, the underlying
/// mobile-money transaction.
class ServiceReceipt extends ReceiptResult {
  /// Help24's own stable document number, e.g. HLP-2026-000184.
  final String receiptNumber;
  final DateTime? issuedAt;

  /// Help24's transaction id — NOT the M-Pesa reference.
  final String transactionId;
  final String postId;

  final String serviceTitle;
  final String? serviceDescription;
  final String? category;
  final String? location;

  final String? customerName;
  final String? providerName;

  final String paymentMethod; // mpesa | airtel_money

  /// The underlying mobile-money reference. Present only for the party who
  /// paid; [providerReferenceVisible] distinguishes "withheld" from "missing".
  final String? providerReference;
  final bool providerReferenceVisible;

  final double? amount;
  final double? platformFee;
  final double? totalPaid;
  final double? refundedAmount;

  /// PAID | ESCROWED | RELEASED | REFUNDED | PARTIALLY_REFUNDED | DISPUTED
  /// | UNDER_REVIEW
  final String status;
  final String statusExplanation;

  final DateTime? paidAt;
  final DateTime? settledAt;
  final String viewerRole;

  const ServiceReceipt({
    required this.receiptNumber,
    required this.issuedAt,
    required this.transactionId,
    required this.postId,
    required this.serviceTitle,
    required this.serviceDescription,
    required this.category,
    required this.location,
    required this.customerName,
    required this.providerName,
    required this.paymentMethod,
    required this.providerReference,
    required this.providerReferenceVisible,
    required this.amount,
    required this.platformFee,
    required this.totalPaid,
    required this.refundedAmount,
    required this.status,
    required this.statusExplanation,
    required this.paidAt,
    required this.settledAt,
    required this.viewerRole,
  });

  bool get isClient => viewerRole == 'client';

  /// The mobile-money rail as a person would name it.
  String get paymentMethodLabel => switch (paymentMethod) {
        'mpesa' => 'M-Pesa',
        'airtel_money' => 'Airtel Money',
        _ => paymentMethod,
      };

  /// The status in everyday language — never the word "escrow", which is the
  /// app-wide rule (see post_card.dart). [status] is the API value and is left
  /// untouched on the wire; this is only what a person reads.
  ///
  /// These are deliberately the SAME words the settlement label uses on the
  /// history row and the lifecycle banner, so one job cannot describe itself as
  /// "Payment protected" in one place and "ESCROWED" in another.
  String get statusLabel => switch (status) {
        'ESCROWED' => 'PAYMENT PROTECTED',
        'PARTIALLY_REFUNDED' => 'PARTIALLY REFUNDED',
        'UNDER_REVIEW' => 'NEEDS REVIEW',
        'DISPUTED' => 'IN DISPUTE',
        _ => status,
      };

  factory ServiceReceipt.fromJson(Map<String, dynamic> j) {
    final service = (j['service'] as Map<String, dynamic>?) ?? const {};
    return ServiceReceipt(
      receiptNumber: j['receipt_number'] as String? ?? '',
      issuedAt: _date(j['issued_at']),
      transactionId: j['transaction_id'] as String? ?? '',
      postId: j['post_id'] as String? ?? '',
      serviceTitle: service['title'] as String? ?? 'Service',
      serviceDescription: service['description'] as String?,
      category: service['category'] as String?,
      location: service['location'] as String?,
      customerName: j['customer_name'] as String?,
      providerName: j['provider_name'] as String?,
      paymentMethod: j['payment_method'] as String? ?? 'mpesa',
      providerReference: j['provider_reference'] as String?,
      providerReferenceVisible: j['provider_reference_visible'] as bool? ?? false,
      amount: (j['amount'] as num?)?.toDouble(),
      platformFee: (j['platform_fee'] as num?)?.toDouble(),
      totalPaid: (j['total_paid'] as num?)?.toDouble(),
      refundedAmount: (j['refunded_amount'] as num?)?.toDouble(),
      status: j['status'] as String? ?? 'PAID',
      statusExplanation: j['status_explanation'] as String? ?? '',
      paidAt: _date(j['paid_at']),
      settledAt: _date(j['settled_at']),
      viewerRole: j['viewer_role'] as String? ?? 'client',
    );
  }
}

DateTime? _date(dynamic v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
