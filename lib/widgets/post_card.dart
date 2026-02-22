import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/post_model.dart';
import '../providers/auth_provider.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import '../utils/time_utils.dart';
import 'marketplace_card_components.dart';

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
    final textTertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;

    final isRequest = post.type == PostType.request;
    final ctaLabel = isRequest ? 'Respond' : 'View';

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
                  // Top row: avatar, username, timestamp
                  Row(
                    children: [
                      MarketplaceAvatar(
                        imageUrl: post.authorAvatar.isNotEmpty ? post.authorAvatar : null,
                        displayName: authorDisplayName,
                        size: 40,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          authorDisplayName,
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: textPrimary,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        formatRelativeTime(post.createdAt),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: textTertiary.withValues(alpha: 0.9),
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: kCardGap),
                  // Title (max 2 lines, bold)
                  Text(
                    post.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: textPrimary,
                          height: 1.25,
                        ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: kCardGap),
                  // Meta row: location, urgency, difficulty (chips)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      LocationChip(location: post.location),
                      UrgencyChip(urgency: post.urgency),
                      DifficultyChip(difficulty: post.difficulty),
                    ],
                  ),
                  const SizedBox(height: kCardGap),
                  // Description preview (max 2 lines)
                  Text(
                    post.description,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: textTertiary,
                        ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // Optional image (only if exists, rounded, full width)
            if (post.images.isNotEmpty && post.images[0].isNotEmpty) ...[
              const SizedBox(height: kCardGap),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    height: 140,
                    width: double.infinity,
                    child: _buildImage(post.images[0]),
                  ),
                ),
              ),
            ],
            // Bottom row: price + CTA
            Padding(
              padding: const EdgeInsets.fromLTRB(kCardPadding, kCardGap, kCardPadding, kCardPadding),
              child: Row(
                children: [
                  if (post.price > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppTheme.successGreen.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Kes.${formatPriceFull(post.price)}',
                        style: const TextStyle(
                          color: AppTheme.successGreen,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  if (post.price > 0) const SizedBox(width: 10),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: isRequest ? (onRespond ?? onTap) : onTap,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(ctaLabel),
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
        debugPrint('❌ Image load error for $url: $error');
        return Container(
          color: AppTheme.darkCard,
          child: const Icon(Icons.broken_image_outlined, color: AppTheme.darkTextTertiary, size: 32),
        );
      },
    );
  }

}
