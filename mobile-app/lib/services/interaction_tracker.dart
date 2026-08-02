import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

// Backend calls go through the authenticated client: it attaches the Firebase
// ID token the server binds identity from, so the ownership checks in each
// backend service actually mean something. See api_client.dart.
import 'api_client.dart';

import '../config/api_config.dart';
import '../models/post_model.dart';

/// Behavioural events feeding Discover personalisation (ranking signals 9 and
/// 10).
///
/// WHY THIS EXISTS
/// ---------------
/// Before the recommendation engine, Help24 instrumented sponsored cards
/// (`PromotionTracker`) and nothing else. The product knew precisely what
/// advertisers had paid for and nothing at all about what users wanted. There
/// was no data for "increase similar content" to stand on.
///
/// DESIGN — deliberately the same shape as [PromotionTracker]
/// ----------------------------------------------------------
///  * batched (10 events or 8 seconds, whichever comes first);
///  * fire-and-forget — a dropped batch is acceptable, a blocked feed is not;
///  * impressions deduped per feed session, so scrolling up and down does not
///    tell the engine you love a post you scrolled past four times;
///  * silent when signed out — every event is owner-scoped by `user_id`, and
///    there is nobody to attribute an anonymous scroll to.
///
/// WHAT IS NOT SENT
/// ----------------
/// No location trail (the feed sends live coordinates per request instead), no
/// free text except the user's own search queries, and no identifiers for
/// anyone but the subject of the event. See migration 091.
class InteractionTracker {
  static final InteractionTracker instance = InteractionTracker._();
  InteractionTracker._();

  static const int _flushAt = 10;
  static const Duration _flushAfter = Duration(seconds: 8);
  static const Duration _timeout = Duration(seconds: 10);

  /// Cap so a pathological session cannot grow the queue without bound.
  static const int _maxQueue = 200;

  final List<Map<String, dynamic>> _queue = [];
  final Set<String> _seenImpressions = <String>{};
  Timer? _flushTimer;
  String _userId = '';

  /// Bind the tracker to the signed-in user. Pass an empty id on sign-out:
  /// the queue is dropped rather than flushed, so one account's activity can
  /// never be attributed to the next.
  void setUser(String? userId) {
    final next = userId?.trim() ?? '';
    if (next == _userId) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    _queue.clear();
    _seenImpressions.clear();
    _userId = next;
  }

  /// A card became visible. Deduped per feed session — see [resetImpressions].
  void trackImpression(PostModel post) {
    if (!_seenImpressions.add(post.id)) return;
    _enqueue('impression', post: post);
  }

  /// The user opened a listing. The workhorse signal: a deliberate act, cheap
  /// to emit, and the clearest evidence of interest short of applying.
  void trackOpen(PostModel post) => _enqueue('open', post: post);

  /// Bookmarked / un-bookmarked. `unsave` carries a negative event weight, so
  /// undoing a save genuinely walks the affinity back.
  void trackSave(PostModel post, {required bool saved}) =>
      _enqueue(saved ? 'save' : 'unsave', post: post);

  /// Save/unsave from a surface that holds only ids (the shortlist, the
  /// bookmark button on a card). [category] and [authorId] are optional: the
  /// event is still worth recording without them — it just contributes to
  /// fewer affinity dimensions.
  void trackSaveById(
    String postId, {
    required bool saved,
    String? category,
    String? authorId,
  }) {
    if (postId.isEmpty) return;
    _enqueue(
      saved ? 'save' : 'unsave',
      postId: postId,
      authorIdOverride: authorId,
      category: category,
    );
  }

  /// Applied to a request or job / sent an offer.
  void trackApply(PostModel post) => _enqueue('apply', post: post);

  /// Opened a chat about a listing.
  void trackMessage(PostModel post) => _enqueue('message', post: post);

  /// Selected a provider for the job — the strongest signal in the table, and
  /// the seam through which "repeat customers" and "favourite providers"
  /// arrive later at no extra cost.
  void trackHire(PostModel post, {String? providerUserId}) => _enqueue(
        'hire',
        post: post,
        authorIdOverride: providerUserId,
      );

  /// Viewed a provider profile.
  void trackProfileOpen({required String providerUserId, String? profession}) =>
      _enqueue('profile_open', authorIdOverride: providerUserId, profession: profession);

  /// Filtered the feed to a category.
  void trackCategoryOpen(String category) => _enqueue('category_open', category: category);

  /// A SUBMITTED search — never a keystroke.
  ///
  /// "electr" is not something anyone searched for; it is something they were
  /// halfway through typing. Recording prefixes would fill the affinity table
  /// with fragments and make signal 10 measurably worse. Call this on submit,
  /// or after the search box has been idle long enough to count as a decision.
  void trackSearch(String query) {
    final q = query.trim();
    if (q.length < 2) return;
    _enqueue('search', query: q);
  }

  /// New feed session (refresh / tab / filter change): impressions may be
  /// counted again for the fresh render.
  void resetImpressions() => _seenImpressions.clear();

  // ── plumbing ───────────────────────────────────────────────────────────────

  void _enqueue(
    String kind, {
    PostModel? post,
    String? postId,
    String? authorIdOverride,
    String? category,
    String? profession,
    String? query,
  }) {
    if (_userId.isEmpty) return; // owner-scoped: nobody to attribute this to

    final authorId = authorIdOverride ?? post?.authorUserId;
    final resolvedPostId = postId ?? post?.id;
    final resolvedCategory =
        (category != null && category.isNotEmpty) ? category : post?.category.name;

    // Your own listing says nothing about what you want to be shown. Recording
    // it would let anyone bias their own feed by opening their own posts.
    if (authorId != null && authorId == _userId) return;

    _queue.add({
      'kind': kind,
      if (resolvedPostId != null && resolvedPostId.isNotEmpty) 'post_id': resolvedPostId,
      if (authorId != null && authorId.isNotEmpty) 'author_id': authorId,
      if (resolvedCategory != null && resolvedCategory.isNotEmpty)
        'category': resolvedCategory,
      if (profession != null && profession.isNotEmpty) 'profession': profession,
      if (query != null && query.isNotEmpty) 'query': query,
    });

    if (_queue.length > _maxQueue) {
      _queue.removeRange(0, _queue.length - _maxQueue);
    }

    if (_queue.length >= _flushAt) {
      flush();
    } else {
      _flushTimer ??= Timer(_flushAfter, flush);
    }
  }

  /// Send everything queued. Safe to call anytime (screen dispose, app pause).
  /// Never throws: telemetry the user did not ask for must not surface as an
  /// error to someone scrolling a feed.
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_queue.isEmpty || _userId.isEmpty) return;

    final batch = List<Map<String, dynamic>>.from(_queue);
    final userId = _userId;
    _queue.clear();

    try {
      await api
          .post(
            Uri.parse('${ApiConfig.baseUrl}/feed/interactions'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'user_id': userId, 'events': batch}),
          )
          .timeout(_timeout);
    } catch (e) {
      // Dropped on purpose. Re-queueing a failed batch risks replaying it on
      // every subsequent flush and skewing the very affinity it feeds.
      debugPrint('[FEED] interaction flush dropped ${batch.length} events: $e');
    }
  }
}
