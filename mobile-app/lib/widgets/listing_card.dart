import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/attribute_display.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';
import '../utils/post_ownership.dart';
import '../utils/time_utils.dart';
import '../utils/feed_images.dart';
import 'marketplace_card_components.dart';
import 'primitives.dart';

/// ONE ROW FOR EVERY LISTING.
///
/// ── The redesign (picture first, details on the post) ──────────────────
/// The card used to carry seven layers: type and category, title, a chain of
/// extras ("Not yet verified · M-Pesa · Available now"), the author and their
/// tier, the description, the price and a filled action button. It was doing
/// the post screen's job in 165 px, which is why Discover felt cramped however
/// the spacing was tuned.
///
/// A row now answers only what decides whether to open it:
///
///     ┌────────┐  Request  Plumbing                  1mo ago
///     │  96px  │  Edger here anyone in need of plumber
///     │ photo  │  ⌖ Muhoroni
///     └────────┘  Open to offers                       [Urgent]
///
/// The photo leads, and a post without one gets a quiet tile with its category
/// icon, so the feed stays visual. The whole row opens the post. Everything
/// that left the row lives on the post screen, built to hold it: the full
/// description, the provider and their reputation, vetting, M-Pesa readiness,
/// availability, and the action button pinned at the bottom.
///
/// Rows are separated by a hairline, not boxed. Dropping the action button
/// and the author line pays for the larger photo and the air around it, so a
/// phone still shows three to four posts.
///
/// ── What stays on the row ──────────────────────────────────────────────
/// * Lifecycle state ("In progress", "Offer sent") and the author's own
///   management control, because they change what tapping means.
/// * Urgency, or a live countdown: the one fact that expires.
/// * "Sponsored", always. A paid placement is disclosed, never hidden.
/// * Distance and a job's employment type, beside the place: proximity
///   surfaces and the Jobs filter depend on them.
class ListingCard extends StatelessWidget {
  const ListingCard({
    super.key,
    required this.post,
    this.onTap,
    this.onRespond,
    this.sponsored = false,
    this.distanceLabel,
    this.urgentCountdown,
    this.showKind = true,
  });

  final PostModel post;
  final VoidCallback? onTap;

  /// Kept for callers that still pass it. The row no longer carries the
  /// visitor's action button; the post screen does.
  final VoidCallback? onRespond;

  /// Business Promotion: renders this as a sponsored slot. Disclosure is a
  /// LABEL, never a highlight.
  final bool sponsored;

  /// "400 m away", supplied by proximity surfaces.
  final String? distanceLabel;

  /// Live countdown for an urgent window, e.g. "12 min left". Passed only by a
  /// surface that REBUILDS on a timer.
  final String? urgentCountdown;

  /// Whether to say "Request", "Offer" or "Job" before the category. Discover
  /// turns it off on a filtered tab, where every row is the same kind.
  final bool showKind;

  static const double thumb = 96;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final auth = context.watch<AuthProvider>();

    // One ownership rule for the whole app, see utils/post_ownership.dart.
    final isOwner = isListingOwner(
      authorUserId: post.authorUserId,
      viewerUserId: auth.currentUserId,
    );
    final applied =
        context.select<AppProvider, bool>((p) => p.hasAppliedTo(post.id));
    final cta = listingCtaFor(
      type: post.type,
      authorUserId: post.authorUserId,
      viewerUserId: auth.currentUserId ?? '',
      status: post.status,
      hasApplied: applied,
    );

    final hasPhoto = post.images.isNotEmpty && post.images.first.isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.lg + 2),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.borderHairline)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              hasPhoto
                  ? _Thumbnail(
                      url: post.images.first,
                      extra: post.images.length > 1 ? post.images.length : null,
                    )
                  : _CategoryTile(icon: post.category.icon),
              const SizedBox(width: AppSpace.lg - 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TopLine(
                      post: post,
                      showKind: showKind,
                      sponsored: sponsored,
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      post.title,
                      style: AppTypeScale.headingS.copyWith(
                        fontFamily: AppTypeScale.family,
                        color: c.contentPrimary,
                        height: 22 / 16,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpace.xs + 2),
                    _PlaceLine(post: post, distanceLabel: distanceLabel),
                    const SizedBox(height: AppSpace.sm + 2),
                    _BottomLine(
                      post: post,
                      isOwner: isOwner,
                      cta: cta,
                      onTap: onTap,
                      urgentCountdown: urgentCountdown,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────

/// "Request  Plumbing" on the left, the age (or "Sponsored") on the right.
/// Kind and category are told apart by weight, not by a separator.
class _TopLine extends StatelessWidget {
  const _TopLine({
    required this.post,
    required this.showKind,
    required this.sponsored,
  });

  final PostModel post;
  final bool showKind;
  final bool sponsored;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final base = AppTypeScale.meta.copyWith(
      fontFamily: AppTypeScale.family,
      fontSize: 12.5,
      color: c.contentTertiary,
    );
    final kind = switch (post.type) {
      PostType.request => 'Request',
      PostType.offer => 'Offer',
      PostType.job => 'Job',
    };

    return Row(
      children: [
        if (showKind) ...[
          Text(
            kind,
            style: base.copyWith(
              color: c.contentSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            post.category.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base,
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        // A paid placement shows "Sponsored" where the age would be: the
        // disclosure is always on the row, and never styled as a highlight.
        Text(
          sponsored ? 'Sponsored' : formatRelativeTime(post.createdAt),
          style: sponsored
              ? base.copyWith(
                  color: c.contentSecondary,
                  fontWeight: FontWeight.w500,
                )
              : base,
        ),
      ],
    );
  }
}

/// The place, then distance and a job's employment type, each with its own
/// icon so they read as separate facts without a dot chain.
class _PlaceLine extends StatelessWidget {
  const _PlaceLine({required this.post, this.distanceLabel});

  final PostModel post;
  final String? distanceLabel;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final style = AppTypeScale.bodyS.copyWith(
      fontFamily: AppTypeScale.family,
      color: c.contentSecondary,
      height: 18 / 13,
    );

    Widget fact(IconData icon, String text, {bool flexible = false}) {
      final label = Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: c.contentTertiary),
          const SizedBox(width: 4),
          flexible ? Flexible(child: label) : label,
        ],
      );
    }

    final extras = <Widget>[
      if (distanceLabel != null) fact(AppIcons.distance, distanceLabel!),
      // A job's employment type: the Jobs tab filters on it, so the row keeps
      // it.
      if (post.type == PostType.job && post.employmentType != null)
        fact(AppIcons.jobs, post.employmentType!.displayLabel),
    ];

    return Row(
      children: [
        Flexible(
          child: fact(
            AppIcons.location,
            post.location.isEmpty ? 'Kenya' : post.location,
            flexible: true,
          ),
        ),
        for (final e in extras) ...[
          const SizedBox(width: AppSpace.md),
          e,
        ],
      ],
    );
  }
}

/// The price on the left. On the right, at most one thing: the author's own
/// control, the listing's state, what the viewer already did, or urgency.
class _BottomLine extends StatelessWidget {
  const _BottomLine({
    required this.post,
    required this.isOwner,
    required this.cta,
    this.onTap,
    this.urgentCountdown,
  });

  final PostModel post;
  final bool isOwner;
  final ListingCta cta;
  final VoidCallback? onTap;
  final String? urgentCountdown;

  @override
  Widget build(BuildContext context) {
    final money = cardMoneyLabel(
      type: post.type,
      price: post.price,
      pricingType: post.pricingType,
    );
    // "Open to offers" is the ABSENCE of a budget, so it is quiet.
    final isPlaceholder = money == 'Open to offers';
    final trailing = _trailing();

    if (money == null && trailing == null) return const SizedBox.shrink();

    return Row(
      children: [
        Expanded(
          child: money == null
              ? const SizedBox.shrink()
              : MoneyLabel(money, muted: isPlaceholder),
        ),
        if (trailing != null) ...[
          const SizedBox(width: AppSpace.sm),
          trailing,
        ],
      ],
    );
  }

  Widget? _trailing() {
    // The author's own listing: their management control, never an action.
    if (isOwner) {
      return OwnerCta(
        type: post.type,
        status: post.status,
        applicationCount: post.applications.length,
        payoutInProgress: post.payoutInProgress,
        onTap: onTap,
      );
    }

    // A listing that is no longer open says what became of it, once.
    if (cta == ListingCta.unavailable) {
      final (label, tone) = (post.status == 'completed' && post.payoutInProgress)
          ? ('Finalizing', ChipTone.caution)
          : switch (post.status) {
              'completed' => ('Completed', ChipTone.positive),
              'disputed' => ('In dispute', ChipTone.critical),
              'cancelled' => ('Closed', ChipTone.neutral),
              _ => ('In progress', ChipTone.info),
            };
      return AppChip(label: label, tone: tone);
    }

    // Already responded: reflect it, so nobody wonders whether it went.
    if (cta == ListingCta.applied) {
      return AppChip(
        label: switch (post.type) {
          PostType.request => 'Offer sent',
          PostType.job => 'Applied',
          PostType.offer => 'Enquired',
        },
        tone: ChipTone.positive,
        icon: AppIcons.success,
      );
    }

    // A live window outranks a static label: it tells a provider whether it
    // is still worth answering.
    if (urgentCountdown != null) {
      return AppChip(
        label: urgentCountdown!,
        tone: ChipTone.critical,
        icon: AppIcons.jobInProgress,
        solid: true,
      );
    }
    if (post.urgency == Urgency.urgent && post.status == 'open') {
      return const AppChip(label: 'Urgent', tone: ChipTone.critical);
    }
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────

/// Stands in for a photo, so a post without one keeps the row's rhythm.
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      width: ListingCard.thumb,
      height: ListingCard.thumb,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: AppRadius.mdAll,
      ),
      child: Icon(icon, size: 28, color: c.contentTertiary),
    );
  }
}

/// The cover photo.
///
/// ZERO fade and NO spinner, deliberately. `AppProvider` warms every visible
/// post's cover from the same data that produced the card, so the bytes are
/// usually decoded by the time this builds. A genuinely cold image sits on a
/// flat tone.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url, this.extra});

  final String url;

  /// Total photo count, when there is more than one.
  final int? extra;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget broken() => Container(
          color: c.surfaceSunken,
          child: Icon(AppIcons.imageBroken, color: c.contentTertiary, size: 22),
        );
    // Decoded at thumbnail size, the same key the feed warms
    // (utils/feed_images.dart), so a warmed cover paints on the first frame.
    Widget image(String src, Widget Function() onError) => CachedNetworkImage(
          imageUrl: src,
          memCacheWidth: kFeedThumbDecodeWidth,
          fit: BoxFit.cover,
          fadeInDuration: Duration.zero,
          fadeOutDuration: Duration.zero,
          placeholderFadeInDuration: Duration.zero,
          placeholder: (_, __) => Container(color: c.surfaceSunken),
          errorWidget: (_, __, ___) => onError(),
        );
    // The small JPEG made at upload, or the photo itself for a post that has
    // none. A missing thumbnail is remembered for the session.
    final src = feedCardImageUrl(url);
    return ClipRRect(
      borderRadius: AppRadius.mdAll,
      child: SizedBox(
        width: ListingCard.thumb,
        height: ListingCard.thumb,
        child: Stack(
          fit: StackFit.expand,
          children: [
            image(
              src,
              src == url
                  ? broken
                  : () {
                      markFeedThumbMissing(src);
                      return image(url, broken);
                    },
            ),
            if (extra != null)
              Positioned(
                right: 6,
                bottom: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    '$extra',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
