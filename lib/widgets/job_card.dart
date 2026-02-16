import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/post_model.dart';
import '../theme/app_theme.dart';
import '../utils/time_utils.dart';
import 'marketplace_card_components.dart';

class JobCard extends StatelessWidget {
  final JobModel job;
  final VoidCallback? onTap;
  final VoidCallback? onApply;

  const JobCard({
    super.key,
    required this.job,
    this.onTap,
    this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textTertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(kCardRadius),
          border: Border.all(color: borderColor, width: 1),
          boxShadow: [
            if (isDark)
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(kCardPadding, kCardPadding, kCardPadding, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top row: avatar, author name, timestamp
                  Row(
                    children: [
                      MarketplaceAvatar(
                        imageUrl: job.authorAvatarUrl.isNotEmpty ? job.authorAvatarUrl : null,
                        displayName: job.authorName,
                        size: 40,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          job.authorName,
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: textPrimary,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        formatRelativeTime(job.postedAt),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: textTertiary.withValues(alpha: 0.9),
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: kCardGap),
                  // Title (max 2 lines, bold)
                  Text(
                    job.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: textPrimary,
                          height: 1.25,
                        ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: kCardGap),
                  // Meta row: location, urgency (Flexible for jobs), difficulty (Any)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      LocationChip(location: job.location),
                      const UrgencyChip(urgency: Urgency.flexible),
                      const DifficultyChip(difficulty: Difficulty.any),
                      // Job type as extra chip
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryAccent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          job.type,
                          style: const TextStyle(
                            color: AppTheme.primaryAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: kCardGap),
                  // Description preview (max 2 lines)
                  if (job.description.isNotEmpty)
                    Text(
                      job.description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: textTertiary,
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            // Optional image (only if exists)
            if (job.images.isNotEmpty && job.images[0].isNotEmpty) ...[
              const SizedBox(height: kCardGap),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    height: 140,
                    width: double.infinity,
                    child: _buildImage(job.images[0]),
                  ),
                ),
              ),
            ],
            // Bottom row: price (pay) + CTA (Apply / Application Sent)
            Padding(
              padding: const EdgeInsets.fromLTRB(kCardPadding, kCardGap, kCardPadding, kCardPadding),
              child: Row(
                children: [
                  if (job.pay.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppTheme.successGreen.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        job.pay,
                        style: const TextStyle(
                          color: AppTheme.successGreen,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (job.pay.isNotEmpty) const SizedBox(width: 10),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: job.hasApplied ? null : onApply,
                        style: job.hasApplied
                            ? FilledButton.styleFrom(
                                backgroundColor: borderColor,
                                foregroundColor: textTertiary,
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              )
                            : FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                        child: Text(job.hasApplied ? 'Application Sent' : 'Apply'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: 0.03, end: 0);
  }

  Widget _buildImage(String url) {
    if (url.isEmpty) {
      return Container(
        color: AppTheme.darkCard,
        child: const Icon(Icons.image_not_supported, color: AppTheme.darkTextTertiary),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      placeholder: (context, url) => Container(
        color: AppTheme.darkCard,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      errorWidget: (context, url, error) {
        debugPrint('❌ Job image load error for $url: $error');
        return Container(
          color: AppTheme.darkCard,
          child: const Icon(Icons.broken_image_outlined, color: AppTheme.darkTextTertiary, size: 32),
        );
      },
    );
  }
}
