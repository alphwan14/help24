import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:iconsax/iconsax.dart';
import '../models/post_model.dart';
import '../providers/auth_provider.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import '../utils/time_utils.dart';
import 'marketplace_card_components.dart';

/// Design tokens aligned with PostCard.
const double _kPadding = 16;
const double _kGap = 12;
const double _kRadius = 16;
const double _kAvatarSize = 36;
const double _kMediaHeight = 72;

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
    final auth = context.watch<AuthProvider>();
    final isCurrentUser = job.authorUserId.isNotEmpty && job.authorUserId == auth.currentUserId;
    final authorDisplayName = (job.authorName.isNotEmpty && job.authorName != '?')
        ? job.authorName
        : (isCurrentUser && auth.currentUserName.isNotEmpty
            ? auth.currentUserName
            : job.authorName);

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final textTertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(_kRadius),
          border: Border.all(color: borderColor, width: 1),
          boxShadow: [
            if (isDark)
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 8,
                offset: const Offset(0, 2),
              )
            else
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(_kPadding, _kPadding, _kPadding, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top row: category label (left), timestamp (right)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _JobCategoryBadge(label: job.categoryName),
                      Text(
                        formatRelativeTime(job.postedAt),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: textTertiary,
                              fontSize: 12,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: _kGap),

                  // Title — bold, max 2 lines
                  Text(
                    job.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: textPrimary,
                          height: 1.28,
                          fontSize: 16,
                        ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: _kGap),

                  // Difficulty & Urgency as small tags under title
                  Row(
                    children: [
                      _SmallTag(
                        label: job.difficulty == Difficulty.any ? job.type : job.difficultyText,
                        color: job.difficulty == Difficulty.any
                            ? AppTheme.primaryAccent
                            : _difficultyColor(job.difficulty),
                      ),
                      const SizedBox(width: 6),
                      _SmallTag(
                        label: job.urgencyText,
                        color: job.urgencyColor,
                      ),
                    ],
                  ),
                  const SizedBox(height: _kGap),

                  // User info row: avatar, name + rating, location (professional icon)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarketplaceAvatar(
                        imageUrl: job.authorAvatarUrl.isNotEmpty ? job.authorAvatarUrl : null,
                        displayName: authorDisplayName,
                        size: _kAvatarSize,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    authorDisplayName,
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                          fontWeight: FontWeight.w500,
                                          color: textPrimary,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                _UserRatingChip(
                                  averageRating: job.rating,
                                  reviewCount: job.authorReviewCount,
                                  mutedColor: textTertiary,
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Icon(
                                  Icons.location_on_outlined,
                                  size: 14,
                                  color: textSecondary,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    job.location.isEmpty ? 'Kenya' : job.location,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: textSecondary,
                                          fontSize: 12,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: _kGap),

                  // Description preview
                  if (job.description.isNotEmpty)
                    Text(
                      job.description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: textTertiary,
                            height: 1.35,
                            fontSize: 13,
                          ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),

            // Media: small thumbnail or photo count
            if (job.images.isNotEmpty && job.images[0].isNotEmpty) ...[
              const SizedBox(height: _kGap),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: _kPadding),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    height: _kMediaHeight,
                    width: double.infinity,
                    child: _buildImage(job.images[0]),
                  ),
                ),
              ),
            ] else if (job.images.length > 1) ...[
              const SizedBox(height: _kGap),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: _kPadding),
                child: Row(
                  children: [
                    Icon(Iconsax.gallery, size: 18, color: textTertiary),
                    const SizedBox(width: 6),
                    Text(
                      '${job.images.length} photos',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: textTertiary,
                            fontSize: 12,
                          ),
                    ),
                  ],
                ),
              ),
            ],

            // Bottom row: price (left), Apply (right)
            Padding(
              padding: const EdgeInsets.fromLTRB(_kPadding, _kGap, _kPadding, _kPadding),
              child: Row(
                children: [
                  if (job.pay.isNotEmpty)
                    Text(
                      normalizePayDisplay(job.pay),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: AppTheme.successGreen,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                    ),
                  if (job.pay.isNotEmpty) const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: job.hasApplied ? null : onApply,
                        style: job.hasApplied
                            ? FilledButton.styleFrom(
                                backgroundColor: borderColor,
                                foregroundColor: textTertiary,
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                minimumSize: const Size(0, 44),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              )
                            : FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                minimumSize: const Size(0, 44),
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
    ).animate().fadeIn(duration: 300.ms).slideY(begin: 0.02, end: 0);
  }

  static Color _difficultyColor(Difficulty d) {
    switch (d) {
      case Difficulty.easy: return const Color(0xFF4CAF50);
      case Difficulty.medium: return const Color(0xFFFF9800);
      case Difficulty.hard: return const Color(0xFFE53935);
      case Difficulty.any: return AppTheme.primaryAccent;
    }
  }

  Widget _buildImage(String url) {
    if (url.isEmpty) {
      return Container(
        color: AppTheme.darkCard,
        child: const Icon(Icons.image_not_supported, color: AppTheme.darkTextTertiary, size: 28),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      placeholder: (context, url) => Container(
        color: AppTheme.darkCard,
        child: const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
      ),
      errorWidget: (context, url, error) => Container(
        color: AppTheme.darkCard,
        child: const Icon(Icons.broken_image_outlined, color: AppTheme.darkTextTertiary, size: 28),
      ),
    );
  }
}

/// Small category badge for jobs (e.g. "Job", "Full-time", or category name).
class _JobCategoryBadge extends StatelessWidget {
  final String label;

  const _JobCategoryBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.primaryAccent.withValues(alpha: isDark ? 0.2 : 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: AppTheme.primaryAccent,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// Small tag for difficulty/urgency (e.g. [Medium] [Urgent]).
class _SmallTag extends StatelessWidget {
  final String label;
  final Color color;

  const _SmallTag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Rating or "New" — same as PostCard. Re-export from post_card would require circular dependency; duplicate minimal widget here.
class _UserRatingChip extends StatelessWidget {
  final double averageRating;
  final int reviewCount;
  final Color mutedColor;

  const _UserRatingChip({
    required this.averageRating,
    required this.reviewCount,
    required this.mutedColor,
  });

  @override
  Widget build(BuildContext context) {
    final hasRatings = reviewCount > 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (hasRatings) ...[
          Icon(Icons.star_rounded, size: 14, color: mutedColor),
          const SizedBox(width: 2),
          Text(
            '${averageRating.toStringAsFixed(1)} ($reviewCount)',
            style: TextStyle(
              fontSize: 11,
              color: mutedColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ] else
          Text(
            'New',
            style: TextStyle(
              fontSize: 11,
              color: mutedColor,
              fontWeight: FontWeight.w500,
            ),
          ),
      ],
    );
  }
}
