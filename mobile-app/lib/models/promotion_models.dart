import 'post_model.dart';

/// Business Promotion ("Promote Business") models.
///
/// A promotion is always a genuine marketplace object: the sponsored card IS a
/// normal offer post rendered by the ordinary PostCard, with a subtle
/// "Sponsored" tag. These models mirror the backend /promotions API.

/// A fixed-price promotion package (pricing lives in the DB, never in code).
class PromotionPackage {
  final String id;
  final String name;
  final String description;

  /// Whole KES. Null only for custom (enterprise) packages.
  final int? priceKes;
  final int durationDays;
  final bool isCustom;

  const PromotionPackage({
    required this.id,
    required this.name,
    required this.description,
    required this.priceKes,
    required this.durationDays,
    required this.isCustom,
  });

  factory PromotionPackage.fromJson(Map<String, dynamic> json) {
    return PromotionPackage(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      priceKes: json['price_kes'] is num ? (json['price_kes'] as num).toInt() : null,
      durationDays: json['duration_days'] is num ? (json['duration_days'] as num).toInt() : 0,
      isCustom: json['is_custom'] == true,
    );
  }

  /// Purchasable in-app right now (enterprise is arranged with support).
  bool get isPurchasable => !isCustom && priceKes != null && priceKes! > 0;
}

/// Campaign lifecycle states — mirrors the backend state machine.
enum CampaignStatus {
  draft,
  awaitingPayment,
  pendingReview,
  active,
  paused,
  rejected,
  completed,
  expired,
  cancelled,
  unknown,
}

CampaignStatus campaignStatusFromString(String? value) {
  switch (value) {
    case 'draft': return CampaignStatus.draft;
    case 'awaiting_payment': return CampaignStatus.awaitingPayment;
    case 'pending_review': return CampaignStatus.pendingReview;
    case 'active': return CampaignStatus.active;
    case 'paused': return CampaignStatus.paused;
    case 'rejected': return CampaignStatus.rejected;
    case 'completed': return CampaignStatus.completed;
    case 'expired': return CampaignStatus.expired;
    case 'cancelled': return CampaignStatus.cancelled;
    default: return CampaignStatus.unknown;
  }
}

extension CampaignStatusX on CampaignStatus {
  String get displayLabel {
    switch (this) {
      case CampaignStatus.draft: return 'Draft';
      case CampaignStatus.awaitingPayment: return 'Awaiting payment';
      case CampaignStatus.pendingReview: return 'In review';
      case CampaignStatus.active: return 'Live';
      case CampaignStatus.paused: return 'Paused';
      case CampaignStatus.rejected: return 'Not approved';
      case CampaignStatus.completed: return 'Completed';
      case CampaignStatus.expired: return 'Expired';
      case CampaignStatus.cancelled: return 'Cancelled';
      case CampaignStatus.unknown: return 'Unknown';
    }
  }

  bool get isLiveOrPaused => this == CampaignStatus.active || this == CampaignStatus.paused;

  bool get isTerminal =>
      this == CampaignStatus.rejected ||
      this == CampaignStatus.completed ||
      this == CampaignStatus.expired ||
      this == CampaignStatus.cancelled;
}

/// A promotion campaign for one of the owner's offer posts.
class PromotionCampaign {
  final String id;
  final String ownerUserId;
  final String? postId;
  final String postTitle;
  final String packageId;
  final String packageName;
  final int priceKes;
  final int durationDays;
  final CampaignStatus status;
  final String rawStatus;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final DateTime createdAt;
  final int daysRemaining;
  final String? rejectionReason;

  const PromotionCampaign({
    required this.id,
    required this.ownerUserId,
    required this.postId,
    required this.postTitle,
    required this.packageId,
    required this.packageName,
    required this.priceKes,
    required this.durationDays,
    required this.status,
    required this.rawStatus,
    required this.startsAt,
    required this.endsAt,
    required this.createdAt,
    required this.daysRemaining,
    required this.rejectionReason,
  });

  factory PromotionCampaign.fromJson(Map<String, dynamic> json) {
    final rawStatus = json['status']?.toString() ?? '';
    return PromotionCampaign(
      id: json['id']?.toString() ?? '',
      ownerUserId: json['owner_user_id']?.toString() ?? '',
      postId: json['post_id']?.toString(),
      postTitle: json['post_title']?.toString() ?? 'Your listing',
      packageId: json['package_id']?.toString() ?? '',
      packageName: json['package_name']?.toString() ?? '',
      priceKes: json['price_kes'] is num ? (json['price_kes'] as num).toInt() : 0,
      durationDays: json['duration_days'] is num ? (json['duration_days'] as num).toInt() : 0,
      status: campaignStatusFromString(rawStatus),
      rawStatus: rawStatus,
      startsAt: json['starts_at'] != null ? DateTime.tryParse(json['starts_at'].toString()) : null,
      endsAt: json['ends_at'] != null ? DateTime.tryParse(json['ends_at'].toString()) : null,
      createdAt: json['created_at'] != null
          ? (DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now())
          : DateTime.now(),
      daysRemaining: json['days_remaining'] is num ? (json['days_remaining'] as num).toInt() : 0,
      rejectionReason: json['rejection_reason']?.toString(),
    );
  }
}

/// One promotion payment (M-Pesa) for the Payment History screen.
class PromotionPaymentRecord {
  final String id;
  final String campaignId;
  final int amountKes;
  final String status; // pending | paid | failed
  final String? mpesaReceipt;
  final String? failureReason;
  final DateTime createdAt;
  final String packageName;
  final String postTitle;

  const PromotionPaymentRecord({
    required this.id,
    required this.campaignId,
    required this.amountKes,
    required this.status,
    required this.mpesaReceipt,
    required this.failureReason,
    required this.createdAt,
    required this.packageName,
    required this.postTitle,
  });

  factory PromotionPaymentRecord.fromJson(Map<String, dynamic> json) {
    final campaign = json['promotion_campaigns'];
    return PromotionPaymentRecord(
      id: json['id']?.toString() ?? '',
      campaignId: json['campaign_id']?.toString() ?? '',
      amountKes: json['amount_kes'] is num ? (json['amount_kes'] as num).toInt() : 0,
      status: json['status']?.toString() ?? '',
      mpesaReceipt: json['mpesa_receipt']?.toString(),
      failureReason: json['failure_reason']?.toString(),
      createdAt: json['created_at'] != null
          ? (DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now())
          : DateTime.now(),
      packageName: campaign is Map ? (campaign['package_name']?.toString() ?? '') : '',
      postTitle: campaign is Map ? (campaign['post_title']?.toString() ?? '') : '',
    );
  }
}

/// Feed-composition knobs served alongside slots (configurable server-side).
class ServingConfig {
  /// Organic cards before the first sponsored slot.
  final int discoverFirstAfter;

  /// Organic cards between sponsored slots.
  final int discoverGap;

  const ServingConfig({this.discoverFirstAfter = 7, this.discoverGap = 8});

  factory ServingConfig.fromJson(Map<String, dynamic> json) {
    return ServingConfig(
      discoverFirstAfter:
          json['discover_first_after'] is num ? (json['discover_first_after'] as num).toInt() : 7,
      discoverGap: json['discover_gap'] is num ? (json['discover_gap'] as num).toInt() : 8,
    );
  }
}

/// One sponsored slot: a real offer post + the campaign that promoted it.
class SponsoredSlot {
  final String campaignId;
  final String placement;
  final double? distanceKm;
  final PostModel post;

  const SponsoredSlot({
    required this.campaignId,
    required this.placement,
    required this.distanceKm,
    required this.post,
  });

  factory SponsoredSlot.fromJson(Map<String, dynamic> json) {
    return SponsoredSlot(
      campaignId: json['campaign_id']?.toString() ?? '',
      placement: json['placement']?.toString() ?? '',
      distanceKm: json['distance_km'] is num ? (json['distance_km'] as num).toDouble() : null,
      post: PostModel.fromJson(Map<String, dynamic>.from(json['post'] as Map)),
    );
  }
}

/// GET /promotions/slots response.
class SlotsResult {
  final String placement;
  final List<SponsoredSlot> items;
  final ServingConfig serving;

  const SlotsResult({
    required this.placement,
    required this.items,
    required this.serving,
  });

  factory SlotsResult.fromJson(Map<String, dynamic> json) {
    return SlotsResult(
      placement: json['placement']?.toString() ?? '',
      items: (json['items'] is List)
          ? (json['items'] as List)
              .whereType<Map>()
              .map((e) => SponsoredSlot.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      serving: json['serving'] is Map
          ? ServingConfig.fromJson(Map<String, dynamic>.from(json['serving'] as Map))
          : const ServingConfig(),
    );
  }

  static const empty = SlotsResult(placement: '', items: [], serving: ServingConfig());
}

/// One day of the campaign analytics trend.
class CampaignDailyStat {
  final String day; // yyyy-MM-dd (Nairobi calendar day)
  final int impressions;
  final int clicks;

  const CampaignDailyStat({required this.day, required this.impressions, required this.clicks});

  factory CampaignDailyStat.fromJson(Map<String, dynamic> json) {
    return CampaignDailyStat(
      day: json['day']?.toString() ?? '',
      impressions: json['impressions'] is num ? (json['impressions'] as num).toInt() : 0,
      clicks: json['clicks'] is num ? (json['clicks'] as num).toInt() : 0,
    );
  }
}

/// The owner dashboard: "is promoting my business working?"
class CampaignAnalytics {
  final PromotionCampaign campaign;
  final int impressions;
  final int impressionsDiscover;
  final int impressionsSearch;
  final int impressionsCategory;
  final int impressionsNearby;
  final int clicks;
  final int profileViews;
  final int phoneTaps;
  final int whatsappTaps;
  final int messages;
  final double ctr;
  final List<CampaignDailyStat> daily;

  const CampaignAnalytics({
    required this.campaign,
    required this.impressions,
    required this.impressionsDiscover,
    required this.impressionsSearch,
    required this.impressionsCategory,
    required this.impressionsNearby,
    required this.clicks,
    required this.profileViews,
    required this.phoneTaps,
    required this.whatsappTaps,
    required this.messages,
    required this.ctr,
    required this.daily,
  });

  factory CampaignAnalytics.fromJson(Map<String, dynamic> json) {
    final totals = json['totals'] is Map
        ? Map<String, dynamic>.from(json['totals'] as Map)
        : <String, dynamic>{};
    int n(String key) => totals[key] is num ? (totals[key] as num).toInt() : 0;
    return CampaignAnalytics(
      campaign: PromotionCampaign.fromJson(
        json['campaign'] is Map
            ? Map<String, dynamic>.from(json['campaign'] as Map)
            : <String, dynamic>{},
      ),
      impressions: n('impressions'),
      impressionsDiscover: n('impressions_discover'),
      impressionsSearch: n('impressions_search'),
      impressionsCategory: n('impressions_category'),
      impressionsNearby: n('impressions_nearby'),
      clicks: n('clicks'),
      profileViews: n('profile_views'),
      phoneTaps: n('phone_taps'),
      whatsappTaps: n('whatsapp_taps'),
      messages: n('messages'),
      ctr: totals['ctr'] is num ? (totals['ctr'] as num).toDouble() : 0,
      daily: (json['daily'] is List)
          ? (json['daily'] as List)
              .whereType<Map>()
              .map((e) => CampaignDailyStat.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }
}
