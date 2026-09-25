import 'package:flutter/material.dart';

import '../models/post_model.dart';
import 'listing_card.dart';

/// A listing in a feed.
///
/// ── This is now a NAME, not an implementation ───────────────────────────
/// The 712 lines that used to live here were one of two renderings of a single
/// concept; `JobCard` was the other. Both now delegate to [ListingCard], which
/// is the only place a listing is drawn.
///
/// The wrapper stays because three screens (Discover, My Posts, Urgent
/// Requests) call `PostCard` and those call sites are correct as written —
/// renaming them would be churn with nothing to show. It also keeps the door
/// open: if a surface ever needs a genuinely different listing rendering, it
/// gets its own widget rather than a flag on this one.
///
/// Everything this used to own — `_SmallTag`, `_StatusBadge`, `_CategoryBadge`,
/// `_SponsoredTag`, `_RequestTakenChip` — is gone. Those five near-identical
/// pill implementations are one `AppChip` with a `ChipTone`.
class PostCard extends StatelessWidget {
  const PostCard({
    super.key,
    required this.post,
    this.onTap,
    this.onRespond,
    this.sponsored = false,
    this.distanceLabel,
    this.urgentCountdown,
  });

  final PostModel post;
  final VoidCallback? onTap;
  final VoidCallback? onRespond;

  /// Business Promotion: renders this card as a sponsored slot.
  final bool sponsored;

  /// "400 m away" — supplied by proximity surfaces only.
  final String? distanceLabel;

  /// Live countdown for an urgent window, e.g. "12 min left".
  final String? urgentCountdown;

  @override
  Widget build(BuildContext context) {
    return ListingCard(
      post: post,
      onTap: onTap,
      onRespond: onRespond,
      sponsored: sponsored,
      distanceLabel: distanceLabel,
      urgentCountdown: urgentCountdown,
    );
  }
}
