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
import 'feed_card_tokens.dart';

/// Design tokens for this card (production layout).
const double _kPadding = FeedCardTokens.padding;
const double _kGap = FeedCardTokens.gap;
const double _kRadius = FeedCardTokens.radius;
const double _kAvatarSize = FeedCardTokens.avatarSize;
const double _kMediaHeight = FeedCardTokens.mediaSize;

class PostCard extends StatelessWidget {
  final PostModel post;
  final VoidCallback? onTap;
  final VoidCallback? onRespond;

  const PostCard({
    super.key,
    required this.post,
    this.onTap,
    this.onRespond,
  });

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final isCurrentUser = post.authorUserId.isNotEmpty && post.authorUserId == auth.currentUserId;
    final authorDisplayName = (post.authorName.isNotEmpty && post.authorName != '?')
        ? post.authorName
        : (isCurrentUser && auth.currentUserName.isNotEmpty
            ? auth.currentUserName
            : post.authorName);

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final textTertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;

    final isRequest = post.type == PostType.request;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: FeedCardTokens.cardBottomMargin),
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
                  // Top row: type badge, category badge (left), timestamp (right)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: post.typeBadgeColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: post.typeBadgeColor.withValues(alpha: 0.5),
                                  width: 1,
                                ),
                              ),
                              child: Text(
                                post.typeDisplayLabel,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: post.typeBadgeColor,
                                ),
                              ),
                            ),
                            _CategoryBadge(category: post.category),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatRelativeTime(post.createdAt),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: textTertiary,
                              fontSize: 12,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  // Title — prominent, bold, max 2 lines
                  Text(
                    post.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: textPrimary,
                          height: 1.24,
                          fontSize: 15,
                        ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),

                  // Difficulty & Urgency as small tags — wrap to avoid overflow
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _SmallTag(
                        label: post.difficultyText,
                        color: post.difficultyColor,
                      ),
                      _SmallTag(
                        label: post.urgencyText,
                        color: post.urgencyColor,
                      ),
                      if (post.type == PostType.offer && post.authorHasPhone)
                        _SmallTag(
                          label: '✔ Verified Provider',
                          color: AppTheme.successGreen,
                        ),
                      // Status badge — visible to all users for non-open lifecycle states
                      if (post.status != 'open' && post.status.isNotEmpty)
                        _StatusBadge(status: post.status),
                      // Activity indicator — application demand on open request posts
                      if (isRequest && post.status == 'open' && post.applications.isNotEmpty)
                        _SmallTag(
                          label: '${post.applications.length} applied',
                          color: AppTheme.primaryAccent,
                          icon: Icons.people_outline,
                        ),
                      // Escrow indicator — funds are held when job is in progress
                      if (post.status == 'assigned')
                        _SmallTag(
                          label: 'Escrow Active',
                          color: AppTheme.warningOrange,
                          icon: Icons.lock_outline,
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  // User info row: avatar, name + rating, location (full format, professional icon)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarketplaceAvatar(
                        imageUrl: post.authorAvatar.isNotEmpty ? post.authorAvatar : null,
                        displayName: authorDisplayName,
                        size: _kAvatarSize,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Name and rating on same line — rating right-aligned, smaller, muted
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
                                  averageRating: post.rating,
                                  reviewCount: post.authorReviewCount,
                                  mutedColor: textTertiary,
                                ),
                              ],
                            ),
                            const SizedBox(height: 1),
                            Row(
                              children: [
                                Icon(
                                  Icons.location_on_outlined,
                                  size: 13,
                                  color: textSecondary,
                                ),
                                const SizedBox(width: 3),
                                Expanded(
                                  child: Text(
                                    post.location.isEmpty ? 'Kenya' : post.location,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: textSecondary,
                                          fontSize: 11.5,
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
                  const SizedBox(height: 6),

                  // Description + optional thumbnail in one row for denser feed cards.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          post.description,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: textTertiary,
                                height: 1.3,
                                fontSize: 12.5,
                              ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (post.images.isNotEmpty && post.images[0].isNotEmpty) ...[
                        const SizedBox(width: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            height: _kMediaHeight,
                            width: _kMediaHeight,
                            child: _buildImage(post.images[0]),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (post.images.length > 1) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Iconsax.gallery, size: 14, color: textTertiary),
                        const SizedBox(width: 4),
                        Text(
                          '${post.images.length} photos',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: textTertiary,
                                fontSize: 11,
                              ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // Bottom row: price (left), primary CTA (right).
            // Own posts show a status-driven owner button; others see the action CTA.
            Padding(
              padding: const EdgeInsets.fromLTRB(_kPadding, 8, _kPadding, _kPadding),
              child: Row(
                children: [
                  if (post.price > 0)
                    Text(
                      formatPriceDisplay(post.price),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: AppTheme.successGreen,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                    ),
                  if (post.price > 0) const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: isCurrentUser
                          ? _OwnerCta(post: post, onTap: onTap, isDark: isDark)
                          : FilledButton(
                              onPressed: onRespond ?? onTap,
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                                minimumSize: const Size(0, FeedCardTokens.buttonMinHeight),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(isRequest ? 'Offer Service' : 'Enquire'),
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

/// Small tag for difficulty/urgency/activity (e.g. [Medium] [Urgent] [12 applied]).
class _SmallTag extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;

  const _SmallTag({required this.label, required this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: icon != null
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 10, color: color),
                const SizedBox(width: 3),
                Text(
                  label,
                  style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w600),
                ),
              ],
            )
          : Text(
              label,
              style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w600),
            ),
    );
  }
}

/// Status badge — bordered chip shown on all cards for assigned/completed/disputed posts.
class _StatusBadge extends StatelessWidget {
  final String status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    String? label;
    Color color = Colors.transparent;
    IconData iconData = Icons.info_outline;

    switch (status) {
      case 'assigned':
        label = 'In Progress';
        color = AppTheme.primaryAccent;
        iconData = Icons.build_circle_outlined;
        break;
      case 'completed':
        label = 'Completed';
        color = AppTheme.successGreen;
        iconData = Icons.check_circle_outline;
        break;
      case 'disputed':
        label = 'Disputed';
        color = AppTheme.errorRed;
        iconData = Icons.flag_outlined;
        break;
    }
    if (label == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(iconData, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

/// Small, subtle category badge — rounded, no playful styling.
class _CategoryBadge extends StatelessWidget {
  final Category category;

  const _CategoryBadge({required this.category});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.primaryAccent.withValues(alpha: isDark ? 0.2 : 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(category.icon, size: 12, color: AppTheme.primaryAccent),
          const SizedBox(width: 4),
          Text(
            category.name,
            style: TextStyle(
              color: AppTheme.primaryAccent,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Owner CTA — replaces the action button when the current user authored the post.
/// Uses an outlined style to visually distinguish "this is mine" from "do something".
class _OwnerCta extends StatelessWidget {
  final PostModel post;
  final VoidCallback? onTap;
  final bool isDark;

  const _OwnerCta({required this.post, required this.onTap, required this.isDark});

  @override
  Widget build(BuildContext context) {
    if (post.type == PostType.offer) {
      return OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.storefront_outlined, size: 15),
        label: const Text('My Offer'),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          minimumSize: const Size(0, FeedCardTokens.buttonMinHeight),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    // Request post — label and colour driven by lifecycle status.
    switch (post.status) {
      case 'assigned':
        return OutlinedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.build_circle_outlined, size: 15),
          label: const Text('In Progress'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            minimumSize: const Size(0, FeedCardTokens.buttonMinHeight),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: AppTheme.primaryAccent,
          ),
        );
      case 'completed':
        return OutlinedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.check_circle_outline, size: 15),
          label: const Text('Completed'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            minimumSize: const Size(0, FeedCardTokens.buttonMinHeight),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: AppTheme.successGreen,
          ),
        );
      case 'disputed':
        return OutlinedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.flag_outlined, size: 15),
          label: const Text('Disputed'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            minimumSize: const Size(0, FeedCardTokens.buttonMinHeight),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: AppTheme.errorRed,
          ),
        );
      default: // 'open'
        final count = post.applications.length;
        final hasApps = count > 0;
        return OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(
            hasApps ? Icons.people_rounded : Icons.people_outline,
            size: 15,
          ),
          label: Text(hasApps ? 'Applications ($count)' : 'Manage'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            minimumSize: const Size(0, FeedCardTokens.buttonMinHeight),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: hasApps
                ? AppTheme.primaryAccent
                : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
          ),
        );
    }
  }
}

/// Rating or "New" label — right of username, same line. Smaller, muted.
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
          Icon(Icons.star_rounded, size: 13, color: mutedColor),
          const SizedBox(width: 2),
          Text(
            '${averageRating.toStringAsFixed(1)} ($reviewCount)',
            style: TextStyle(
              fontSize: 10.5,
              color: mutedColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ] else
          Text(
            'New',
            style: TextStyle(
              fontSize: 10.5,
              color: mutedColor,
              fontWeight: FontWeight.w500,
            ),
          ),
      ],
    );
  }
}
