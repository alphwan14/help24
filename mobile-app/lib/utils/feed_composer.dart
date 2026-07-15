import '../models/post_model.dart';
import '../models/promotion_models.dart';

/// One rendered feed row: an organic post, or a sponsored slot.
class FeedEntry {
  final PostModel post;
  final bool sponsored;
  final String? campaignId;

  const FeedEntry.organic(this.post)
      : sponsored = false,
        campaignId = null;

  const FeedEntry.sponsored(this.post, String this.campaignId) : sponsored = true;
}

/// Pure feed composition — no widgets, no I/O (unit-tested).
///
/// Interleaves sponsored slots into the organic list per the server-provided
/// cadence: the first sponsored card appears after [ServingConfig.discoverFirstAfter]
/// organic cards, then one after every [ServingConfig.discoverGap] organic
/// cards. Guarantees, in order of priority:
///
///  1. The organic order is NEVER changed — sponsored cards are inserted
///     between organic cards, they never displace or reorder them.
///  2. Sponsored cards never cluster (one per gap, by construction).
///  3. A post already present organically is not shown a second time as
///     sponsored (no duplicates; the feed must feel organic).
///  4. A sponsored card is only shown after its required run of organic cards
///     — a short feed with 3 posts shows no sponsored card when firstAfter=7,
///     so thin feeds never feel like ad boards.
class FeedComposer {
  /// Composes one feed page. [slots] beyond what the cadence allows are
  /// dropped (the serving cap already limits them server-side).
  static List<FeedEntry> compose({
    required List<PostModel> organic,
    required List<SponsoredSlot> slots,
    required ServingConfig config,
  }) {
    final entries = <FeedEntry>[];
    if (organic.isEmpty) {
      // No organic content → no sponsored content. Help24 never shows a
      // feed that is only promotions.
      return entries;
    }

    final firstAfter = config.discoverFirstAfter < 1 ? 1 : config.discoverFirstAfter;
    final gap = config.discoverGap < 1 ? 1 : config.discoverGap;

    final organicIds = organic.map((p) => p.id).toSet();
    final pending = slots
        .where((s) => s.post.id.isNotEmpty && !organicIds.contains(s.post.id))
        .toList();

    var slotIndex = 0;
    var organicSinceSlot = 0;
    var nextSlotAt = firstAfter;

    for (final post in organic) {
      entries.add(FeedEntry.organic(post));
      organicSinceSlot++;

      if (slotIndex < pending.length && organicSinceSlot >= nextSlotAt) {
        final slot = pending[slotIndex++];
        entries.add(FeedEntry.sponsored(slot.post, slot.campaignId));
        organicSinceSlot = 0;
        nextSlotAt = gap;
      }
    }

    return entries;
  }
}
