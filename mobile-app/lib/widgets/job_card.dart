import 'package:flutter/material.dart';

import '../models/post_model.dart';
import 'listing_card.dart';

/// A job in the Jobs tab.
///
/// ── Why this is four lines now ──────────────────────────────────────────
/// A job IS a post. `JobModel.toPostModel()` already existed and is what the
/// Jobs tab hands to the shared detail screen, so the two were always the same
/// object — they just had two renderings, 419 lines and 712 lines, that
/// drifted independently. `JobCard` used to draw a plain "Apply" regardless of
/// ownership, so the same job invited its author to apply on one tab and
/// offered them management on another.
///
/// `toPostModel()` carries every field the card draws (it does not carry
/// `company`, which this card never rendered). So there is nothing left to
/// translate: one listing, one card, one verb.
class JobCard extends StatelessWidget {
  const JobCard({
    super.key,
    required this.job,
    this.onTap,
    this.onApply,
  });

  final JobModel job;
  final VoidCallback? onTap;
  final VoidCallback? onApply;

  @override
  Widget build(BuildContext context) {
    return ListingCard(
      post: job.toPostModel(),
      onTap: onTap,
      onRespond: onApply,
    );
  }
}
