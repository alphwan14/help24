import 'package:flutter/material.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// One metadata tag on the preview — location, price, availability, urgency.
///
/// Plain data, so the post screen decides WHAT the card says and
/// [PostPreviewCard] alone decides how it is laid out. An [accent] draws the
/// tag as a status (a coloured dot on a tinted capsule — the urgency tag);
/// otherwise it is a neutral capsule led by [icon].
@immutable
class PreviewTag {
  final IconData? icon;
  final String text;
  final Color? accent;

  const PreviewTag({this.icon, required this.text, this.accent});
}

/// The "Preview your post" card on the last step of posting.
///
/// WHAT WENT WRONG
/// ---------------
/// The card carried `AppRadius.pillAll`, the capsule radius. Flutter scales a
/// corner radius larger than its box down to half the box's shorter side, so a
/// tall card became an oval: its border cut through the category icon at the
/// top and the urgency chip at the bottom — "Flexible" sat half outside the
/// card. It is a content card, so it takes the card rung, `lg`.
///
/// Every piece of content must stay inside the card whatever the post holds,
/// so the layout is flexible rather than trusting typical data:
///   * the card grows with its content and clips it to its own corners, so a
///     photo header always follows the card's shape;
///   * the border is painted in FRONT of the content, so a photo cannot cover
///     the hairline where it meets the edge;
///   * the category name truncates instead of pushing its row past the edge (a
///     custom category is typed by the user and has no length limit);
///   * every tag is one line and ellipsises — a tag is a capsule, and a
///     two-line capsule is the same oval again, smaller;
///   * optional parts (photos, description, tags) take no space when absent.
///
/// See test/post_preview_card_test.dart.
class PostPreviewCard extends StatelessWidget {
  /// Photo header, already sized; the card clips it to its corners.
  final Widget? media;

  final IconData icon;
  final String typeLabel;
  final Color typeColor;
  final String? categoryName;
  final String title;
  final String description;
  final List<PreviewTag> tags;

  /// Schema answers ("Bedrooms: 2"), shown as tags below the metadata.
  final List<String> attributes;

  const PostPreviewCard({
    super.key,
    this.media,
    required this.icon,
    required this.typeLabel,
    required this.typeColor,
    this.categoryName,
    required this.title,
    required this.description,
    this.tags = const [],
    this.attributes = const [],
  });

  /// The card's corner radius — the design system's card rung.
  static const BorderRadius radius = AppRadius.lgAll;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final secondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final trimmedDescription = description.trim();
    final category = categoryName?.trim() ?? '';

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: radius,
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (media != null) media!,
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppTheme.primaryAccent.withValues(alpha: 0.12),
                        borderRadius: AppRadius.mdAll,
                      ),
                      child: Icon(icon, color: AppTheme.primaryAccent),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: typeColor.withValues(alpha: 0.15),
                                  borderRadius: AppRadius.smAll,
                                ),
                                child: Text(
                                  typeLabel,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: typeColor,
                                  ),
                                ),
                              ),
                              if (category.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    category,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(color: secondary),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(title, style: Theme.of(context).textTheme.titleLarge),
                          if (trimmedDescription.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              trimmedDescription,
                              style: Theme.of(context).textTheme.bodyMedium,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [for (final tag in tags) _TagChip(tag: tag)],
                  ),
                ],
                if (attributes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in attributes)
                        _TagChip(tag: PreviewTag(icon: AppIcons.success, text: entry)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One capsule. Single line, always: `ellipsis` alone does not stop a Text
/// from wrapping, and a wrapped capsule is a small oval.
class _TagChip extends StatelessWidget {
  final PreviewTag tag;

  const _TagChip({required this.tag});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = tag.accent;
    final foreground = accent ??
        (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary);

    return Container(
      padding: accent != null
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 5)
          : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: accent != null
            ? accent.withValues(alpha: 0.15)
            : (isDark ? AppTheme.darkSurface : AppTheme.lightBackground),
        borderRadius: AppRadius.pillAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (accent != null)
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            )
          else if (tag.icon != null)
            Icon(tag.icon, size: 14, color: foreground),
          SizedBox(width: accent != null ? 5 : 4),
          Flexible(
            child: Text(
              tag.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: accent != null
                  ? TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w600)
                  : TextStyle(fontSize: 12, color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}
