import 'package:flutter/material.dart';

import '../models/post_model.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';
import '../utils/vetting_labels.dart';

/// The provider-vetting label for a listing (migration 135) as a small badge:
/// "Care checked" / "ID verified" in the positive tone, "Certificate pending" /
/// "Not yet verified" in the caution tone. Renders nothing when there is none.
class VettingBadge extends StatelessWidget {
  final PostModel post;
  const VettingBadge({super.key, required this.post});

  @override
  Widget build(BuildContext context) {
    final label = listingVettingLabel(post);
    if (label == null) return const SizedBox.shrink();
    final c = AppColors.of(context);
    final positive = label.tone == VettingTone.positive;
    final fg = positive ? c.positiveText : c.cautionText;
    final bg = positive ? c.positiveSubtle : c.cautionSubtle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: AppRadius.smAll),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(positive ? AppIcons.verifiedProvider : AppIcons.pending, size: 14, color: fg),
          const SizedBox(width: 4),
          Text(label.text, style: AppTypeScale.meta.copyWith(color: fg, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
