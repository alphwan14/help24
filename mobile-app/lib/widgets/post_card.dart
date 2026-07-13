import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:iconsax/iconsax.dart';
import '../models/attribute_display.dart';
import '../models/post_model.dart';
import '../providers/auth_provider.dart';
import '../services/category_schema_service.dart';
import '../theme/app_theme.dart';
import '../utils/time_utils.dart';
import 'marketplace_card_components.dart';
import 'feed_card_tokens.dart';
import 'reputation_widgets.dart';

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

    // R-4: intent-aware read side. Schema comes from the cache-first registry;
    // when it isn't loaded yet the chips simply don't render (never blocks).
    final schema = CategorySchemaService.instance.schemaFor(post.category.name);
    final timeSignal = timeSignalChip(type: post.type, attributes: post.attributes);
    final highlightChips = highlightChipLabels(
      schema: schema,
      postType: post.type.name,
      attributes: post.attributes,
    );
    final moneyLabel = cardMoneyLabel(
      type: post.type,
      price: post.price,
      pricingType: post.pricingType,
    );

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

                  // Intent-aware tags (R-4): requests show urgency, offers show
                  // availability, jobs show start date — plus up to two
                  // highlight answers from the category questions. The old
                  // difficulty tag is gone (it was never asked; every post
                  // said "Medium").
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (post.type == PostType.request)
                        _SmallTag(
                          label: post.urgencyText,
                          color: post.urgencyColor,
                        ),
                      if (timeSignal != null)
                        _SmallTag(
                          label: timeSignal,
                          color: AppTheme.successGreen,
                        ),
                      for (final chip in highlightChips)
                        _SmallTag(
                          label: chip,
                          color: AppTheme.primaryAccent,
                        ),
                      if (post.type == PostType.offer && post.authorHasPhone)
                        _SmallTag(
                          label: '✔ Verified Provider',
                          color: AppTheme.successGreen,
                        ),
                      // Status badge — visible to all users for non-open lifecycle states
                      if (post.status != 'open' && post.status.isNotEmpty)
                        _StatusBadge(status: post.status, payoutInProgress: post.payoutInProgress),
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
                                // Backend-sourced provider trust (no fake rating).
                                ReputationCompact(
                                  providerId: post.authorUserId,
                                  textColor: textTertiary,
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

                  // Description + optional thumbnail in one row for denser feed
                  // cards. Descriptions are optional for requests (R-1) — an
                  // empty one must not leave a dead gap.
                  if (post.description.trim().isNotEmpty ||
                      (post.images.isNotEmpty && post.images[0].isNotEmpty))
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: post.description.trim().isEmpty
                              ? const SizedBox.shrink()
                              : Text(
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
                  if (moneyLabel != null)
                    Flexible(
                      child: Text(
                        moneyLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: AppTheme.successGreen,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                      ),
                    ),
                  if (moneyLabel != null) const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: isCurrentUser
                          ? _OwnerCta(post: post, onTap: onTap, isDark: isDark)
                          : (isRequest && post.status != 'open')
                              // Request already has a provider — never show "Offer Service".
                              ? _RequestTakenChip(status: post.status, isDark: isDark, payoutInProgress: post.payoutInProgress)
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
  final bool payoutInProgress;

  const _StatusBadge({required this.status, this.payoutInProgress = false});

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
        // Job accepted, but the provider payout is not settled until escrow is
        // 'released'. Never show a green "Completed" while the money is pending.
        if (payoutInProgress) {
          label = 'Finalizing';
          color = AppTheme.warningOrange;
          iconData = Icons.hourglass_top_rounded;
        } else {
          label = 'Completed';
          color = AppTheme.successGreen;
          iconData = Icons.check_circle_outline;
        }
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
          icon: Icon(post.payoutInProgress ? Icons.hourglass_top_rounded : Icons.check_circle_outline, size: 15),
          label: Text(post.payoutInProgress ? 'Finalizing' : 'Completed'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            minimumSize: const Size(0, FeedCardTokens.buttonMinHeight),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: post.payoutInProgress ? AppTheme.warningOrange : AppTheme.successGreen,
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

// _UserRatingChip removed (Phase 3.2C): replaced by ReputationCompact, which is
// sourced from the backend reputation endpoint instead of the fake PostModel.rating.

/// Shown instead of "Offer Service" once a request is no longer open (a provider
/// has been selected / the job is in progress, completed, or disputed).
class _RequestTakenChip extends StatelessWidget {
  final String status;
  final bool isDark;
  final bool payoutInProgress;
  const _RequestTakenChip({required this.status, required this.isDark, this.payoutInProgress = false});

  @override
  Widget build(BuildContext context) {
    final (label, color) = (status == 'completed' && payoutInProgress)
        ? ('Finalizing', AppTheme.warningOrange)
        : switch (status) {
            'completed' => ('Completed', AppTheme.successGreen),
            'disputed' => ('In Dispute', AppTheme.errorRed),
            'cancelled' => ('Closed', AppTheme.lightTextTertiary),
            _ => ('In Progress', AppTheme.primaryAccent),
          };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}
