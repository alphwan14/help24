import 'dart:async';
import '../services/promotion_service.dart';

/// Batches promotion analytics events and dedupes impressions so scrolling
/// back and forth never double-counts a card within one feed session.
///
/// Fire-and-forget by design: a dropped batch is acceptable, a blocked feed
/// is not. Call [reset] when the feed reloads (new search/filter/refresh) so
/// the next render counts fresh impressions.
class PromotionTracker {
  static final PromotionTracker instance = PromotionTracker._();
  PromotionTracker._();

  final Set<String> _seenImpressions = <String>{};
  final List<Map<String, dynamic>> _queue = [];
  Timer? _flushTimer;

  static const int _flushAt = 10;
  static const Duration _flushAfter = Duration(seconds: 8);

  /// A sponsored card became visible in [placement].
  void trackImpression({
    required String campaignId,
    required String placement,
    String? viewerUserId,
  }) {
    final key = '$campaignId:$placement';
    if (!_seenImpressions.add(key)) return; // already counted this session
    _enqueue(campaignId, 'impression', placement, viewerUserId);
  }

  /// A sponsored card was opened (detail sheet). Clicks are intentional acts —
  /// not deduped.
  void trackClick({
    required String campaignId,
    required String placement,
    String? viewerUserId,
  }) {
    _enqueue(campaignId, 'click', placement, viewerUserId);
  }

  /// Contact actions from a sponsored surface: 'phone_tap' | 'whatsapp_tap' |
  /// 'message' | 'profile_view'.
  void trackAction({
    required String campaignId,
    required String eventType,
    String? placement,
    String? viewerUserId,
  }) {
    _enqueue(campaignId, eventType, placement, viewerUserId);
  }

  void _enqueue(String campaignId, String eventType, String? placement, String? viewerUserId) {
    _queue.add({
      'campaign_id': campaignId,
      'event_type': eventType,
      if (placement != null && placement.isNotEmpty) 'placement': placement,
      if (viewerUserId != null && viewerUserId.isNotEmpty) 'viewer_user_id': viewerUserId,
    });
    if (_queue.length >= _flushAt) {
      flush();
    } else {
      _flushTimer ??= Timer(_flushAfter, flush);
    }
  }

  /// Sends everything queued. Safe to call anytime (e.g. on screen dispose).
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_queue.isEmpty) return;
    final batch = List<Map<String, dynamic>>.from(_queue);
    _queue.clear();
    await PromotionService.trackEvents(batch);
  }

  /// New feed session (refresh / search / filter change): impressions may be
  /// counted again for the fresh render.
  void reset() {
    _seenImpressions.clear();
  }
}
