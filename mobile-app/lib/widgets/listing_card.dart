import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/attribute_display.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../services/category_schema_service.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';
import '../utils/post_ownership.dart';
import '../utils/time_utils.dart';
import 'marketplace_card_components.dart';
import 'primitives.dart';
import 'reputation_widgets.dart';

/// ONE CARD FOR EVERY LISTING.
///
/// ── What this replaces ──────────────────────────────────────────────────
/// `PostCard` (712 lines) and `JobCard` (419 lines) were two implementations
/// of one concept. They shared `FeedCardTokens` but not structure, so each
/// re-declared its own decoration, header row, avatar row and CTA — and a job
/// is literally a `PostModel` (`JobModel.toPostModel()`), rendered by the same
/// detail screen either way. Both now delegate here.
///
/// ── The layout change, and why ──────────────────────────────────────────
/// The old card stacked its photo BELOW the author row, so the image column
/// and the text column never shared vertical space and a card with a photo
/// cost 283 px. On a 915 px viewport that is 2.5 cards.
///
/// The photo is now a LEADING element, the way every mature marketplace list
/// does it, so the two columns overlap and the card lands at ~165 px — 4 to 5
/// cards per screen, with no type made smaller.
///
///     ┌──────┐  REQUEST · Plumbing              1mo ago
///     │ 72px │  Kitchen
///     │ img  │  Leak · Toilet
///     └──────┘  ⬤ Karen Brina · New Provider · Annex, Eldoret
///      Open to offers                      [ Offer Service ]
///
/// ── Photo OR description, never both ────────────────────────────────────
/// A photo is PROOF and a description is elaboration, and they compete for
/// exactly the same space. So the card shows the photo when there is one and
/// the description when there is not. Nothing is lost: the full description is
/// one tap away, on a screen built to hold it.
///
/// ── Chips ───────────────────────────────────────────────────────────────
/// The old card could render EIGHT: type, category, urgency, distance, a time
/// signal, two highlight answers, an M-Pesa tag, a status badge, an applied
/// count and a payment-hold tag. On live data a single card showed `Plumbing`,
/// `Leak` and `Toilet` as three VISUALLY IDENTICAL pills, so nothing told the
/// reader which one was the category and which two were answers.
///
/// Now: elaboration is TEXT (two [MetaLine]s, where order carries the meaning
/// that identical pills could not), and a chip is reserved for something that
/// changes the decision — capped at two, in explicit priority order. See
/// [_decisionChips].
class ListingCard extends StatelessWidget {
  const ListingCard({
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

  /// Business Promotion: renders this as a sponsored slot.
  ///
  /// Disclosure is a LABEL, not a highlight. The old card gave sponsored rows
  /// an amber border; a paid placement should be marked, never visually
  /// promoted over the organic cards around it.
  final bool sponsored;

  /// "400 m away" — supplied by proximity surfaces, which have the viewer's
  /// coordinates and for which distance is the deciding fact.
  final String? distanceLabel;

  /// Live countdown for an urgent window, e.g. "12 min left". Passed only by a
  /// surface that REBUILDS on a timer.
  final String? urgentCountdown;

  static const double _thumb = 72;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    // One ownership rule for the whole app — see utils/post_ownership.dart.
    final isOwner = isListingOwner(
      authorUserId: post.authorUserId,
      viewerUserId: auth.currentUserId,
    );
    final authorName = (post.authorName.isNotEmpty && post.authorName != '?')
        ? post.authorName
        : (isOwner && auth.currentUserName.isNotEmpty
            ? auth.currentUserName
            : post.authorName);

    final applied =
        context.select<AppProvider, bool>((p) => p.hasAppliedTo(post.id));
    final cta = listingCtaFor(
      type: post.type,
      authorUserId: post.authorUserId,
      viewerUserId: auth.currentUserId ?? '',
      status: post.status,
      hasApplied: applied,
    );

    final schema = CategorySchemaService.instance.schemaFor(post.category.name);
    final hasPhoto = post.images.isNotEmpty && post.images.first.isNotEmpty;

    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: const EdgeInsets.fromLTRB(
          AppSpace.md + 2, AppSpace.md + 2, AppSpace.md + 2, AppSpace.md),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasPhoto) ...[
                _Thumbnail(
                  url: post.images.first,
                  extra: post.images.length > 1 ? post.images.length : null,
                ),
                const SizedBox(width: AppSpace.md),
              ],
              Expanded(
                child: _TextColumn(
                  post: post,
                  schema: schema,
                  authorName: authorName,
                  hasPhoto: hasPhoto,
                  sponsored: sponsored,
                  distanceLabel: distanceLabel,
                  urgentCountdown: urgentCountdown,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          _ActionRow(
            post: post,
            isOwner: isOwner,
            cta: cta,
            onTap: onTap,
            onRespond: onRespond,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────

class _TextColumn extends StatelessWidget {
  const _TextColumn({
    required this.post,
    required this.schema,
    required this.authorName,
    required this.hasPhoto,
    required this.sponsored,
    this.distanceLabel,
    this.urgentCountdown,
  });

  final PostModel post;
  final dynamic schema;
  final String authorName;
  final bool hasPhoto;
  final bool sponsored;
  final String? distanceLabel;
  final String? urgentCountdown;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    // Line A — what KIND of listing, and in what trade. Always this shape, so
    // the eye can scan a column of cards without re-reading each one.
    final kind = switch (post.type) {
      PostType.request => 'REQUEST',
      PostType.offer => 'OFFER',
      PostType.job => 'JOB',
    };

    // Line B — elaboration, in priority order, ellipsised from the tail.
    // Everything here used to be a chip.
    final timeSignal =
        timeSignalChip(type: post.type, attributes: post.attributes);
    final detail = <String>[
      // Location leads. It used to sit in the author row, where on a card with
      // a thumbnail the text column is only ~240 dp wide, so the name and the
      // place competed and BOTH ellipsised: "Alpho... New Provider  Momb...".
      // It is also the most decision-relevant fact after the title.
      post.location.isEmpty ? 'Kenya' : post.location,
      if (distanceLabel != null) distanceLabel!,
      // A job's employment type. The old JobCard showed this as a chip and the
      // Jobs tab FILTERS on it, so folding the two cards together without it
      // would have quietly dropped a field the user can search by.
      if (post.type == PostType.job && post.employmentType != null)
        post.employmentType!.displayLabel,
      ...highlightChipLabels(
        schema: schema,
        postType: post.type.name,
        attributes: post.attributes,
      ),
      // Payment readiness outranks availability: it is a trust signal, and
      // this line ellipsises from the tail.
      if (post.type == PostType.offer && post.authorHasPhone) 'M-Pesa',
      if (timeSignal != null) timeSignal,
    ];

    // De-duplicated against the detail line. Production has a job whose entire
    // description is "Starts immediately" — which is also exactly what
    // timeSignalChip computes for it, so the card printed it twice.
    final rawDescription = post.description.trim();
    final duplicated = detail.any(
      (d) => d.toLowerCase() == rawDescription.toLowerCase(),
    );
    final description =
        (rawDescription.isEmpty || duplicated) ? null : rawDescription;

    final chips = _decisionChips(context, post, sponsored, urgentCountdown);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: MetaLine([kind, post.category.name],
                  leadingIcon: post.category.icon),
            ),
            const SizedBox(width: AppSpace.sm),
            Text(
              formatRelativeTime(post.createdAt),
              style: AppTypeScale.meta.copyWith(
                fontFamily: AppTypeScale.family,
                color: c.contentTertiary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          post.title,
          style: AppTypeScale.headingS.copyWith(
            fontFamily: AppTypeScale.family,
            color: c.contentPrimary,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        MetaLine(detail, leadingIcon: AppIcons.location),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          Wrap(spacing: 6, runSpacing: 6, children: chips),
        ],
        const SizedBox(height: AppSpace.sm),
        _AuthorLine(post: post, authorName: authorName),
        // The description takes the space the photo would have taken, and only
        // when there is no photo. See the class doc.
        //
        // De-duplicated against the detail line: production has a job whose
        // whole description is "Starts immediately", which is also exactly what
        // timeSignalChip computes for it — so the card said it twice.
        if (!hasPhoto && description != null) ...[
          const SizedBox(height: 6),
          Text(
            description,
            style: AppTypeScale.bodyS.copyWith(
              fontFamily: AppTypeScale.family,
              color: c.contentTertiary,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// At most TWO chips, in this order. Everything that loses is already on a
/// [MetaLine] — nothing is dropped, it is de-emphasised.
///
/// The ordering is the design: a reader scanning a feed can act on at most a
/// couple of signals per card, so the card must decide which ones rather than
/// showing all ten and letting them cancel out.
List<Widget> _decisionChips(
  BuildContext context,
  PostModel post,
  bool sponsored,
  String? urgentCountdown,
) {
  final out = <Widget>[];

  // 1. Paid placement. Disclosure outranks everything and is never styled to
  //    look like an endorsement.
  if (sponsored) {
    out.add(const AppChip(label: 'Sponsored'));
  }

  // 2. A live window. "12 min left" tells a provider whether it is worth
  //    answering; "Urgent" does not. Solid, because it is the one thing on the
  //    card that expires.
  if (urgentCountdown != null) {
    out.add(AppChip(
      label: urgentCountdown,
      tone: ChipTone.critical,
      icon: AppIcons.jobInProgress,
      solid: true,
    ));
  } else if (post.urgency == Urgency.urgent && post.status == 'open') {
    out.add(const AppChip(label: 'Urgent', tone: ChipTone.critical));
  }

  // 3. THERE IS NO STATUS CHIP, deliberately.
  //
  //    The old card drew one — and then the action slot drew the same fact
  //    again, because a listing that is no longer open replaces its CTA with
  //    its state ("In progress", "Completed", "Disputed") for a visitor, and
  //    `OwnerCta` does exactly the same for the author. So every non-open card
  //    said its status twice, in two different shapes.
  //
  //    One place reports lifecycle state: the action slot. See [_ActionRow].

  // 4. Competition. Only on an open request, where it changes whether you
  //    bother.
  if (out.length < 2 &&
      post.type == PostType.request &&
      post.status == 'open' &&
      post.applications.isNotEmpty) {
    out.add(AppChip(
      label: '${post.applications.length} applied',
      icon: AppIcons.applicants,
    ));
  }

  return out.take(2).toList();
}

// ─────────────────────────────────────────────────────────────────────────

class _AuthorLine extends StatelessWidget {
  const _AuthorLine({required this.post, required this.authorName});

  final PostModel post;
  final String authorName;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      children: [
        MarketplaceAvatar(
          imageUrl: post.authorAvatar.isNotEmpty ? post.authorAvatar : null,
          displayName: authorName,
          size: 20,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            authorName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypeScale.bodyS.copyWith(
              fontFamily: AppTypeScale.family,
              color: c.contentSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        // ReputationCompact emits a BARE Text for the no-reviews tier label,
        // with no leading space of its own — so the gap has to be here or the
        // row renders "Karen BrinaNew Provider". The widget is shared with the
        // applicant list, Saved and post detail, so the separator belongs at
        // the call site rather than inside it.
        const SizedBox(width: 6),
        Flexible(
          child: ReputationCompact(
            providerId: post.authorUserId,
            textColor: c.contentTertiary,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.post,
    required this.isOwner,
    required this.cta,
    this.onTap,
    this.onRespond,
  });

  final PostModel post;
  final bool isOwner;
  final ListingCta cta;
  final VoidCallback? onTap;
  final VoidCallback? onRespond;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final money = cardMoneyLabel(
      type: post.type,
      price: post.price,
      pricingType: post.pricingType,
    );
    // "Open to offers" is the ABSENCE of a budget, not a price — so it is
    // quiet. It used to render in successGreen at 2.54:1, which made the
    // least readable colour in the app also the loudest thing beside the CTA.
    final isPlaceholder = money == 'Open to offers';

    return Row(
      children: [
        if (money != null)
          Flexible(child: MoneyLabel(money, muted: isPlaceholder)),
        if (money != null) const SizedBox(width: AppSpace.md),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: _cta(context, c),
          ),
        ),
      ],
    );
  }

  Widget _cta(BuildContext context, AppColors c) {
    if (isOwner) {
      return OwnerCta(
        type: post.type,
        status: post.status,
        applicationCount: post.applications.length,
        payoutInProgress: post.payoutInProgress,
        onTap: onTap,
      );
    }

    // A request that already has a provider never offers "Offer Service".
    if (cta == ListingCta.unavailable) {
      final (label, tone) = (post.status == 'completed' && post.payoutInProgress)
          ? ('Finalizing', ChipTone.caution)
          : switch (post.status) {
              'completed' => ('Completed', ChipTone.positive),
              'disputed' => ('In dispute', ChipTone.critical),
              'cancelled' => ('Closed', ChipTone.neutral),
              _ => ('In progress', ChipTone.info),
            };
      return AppChip(label: label, tone: tone, size: ChipSize.md);
    }

    // Already responded — reflect it and block a duplicate rather than
    // re-inviting the action.
    if (cta == ListingCta.applied) {
      return AppChip(
        label: switch (post.type) {
          PostType.request => 'Offer sent',
          PostType.job => 'Applied',
          PostType.offer => 'Enquired',
        },
        tone: ChipTone.positive,
        size: ChipSize.md,
        icon: AppIcons.success,
      );
    }

    return FilledButton(
      onPressed: onRespond ?? onTap,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        minimumSize: const Size(0, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: AppTypeScale.label.copyWith(
          fontFamily: AppTypeScale.family,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      // A job says "Apply" here exactly as it does in the Jobs tab — the same
      // listing must not offer two different verbs.
      child: Text(switch (post.type) {
        PostType.request => 'Offer Service',
        PostType.job => 'Apply',
        PostType.offer => 'Enquire',
      }),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────

/// The cover photo.
///
/// ZERO fade and NO spinner, deliberately — the contract `MarketplaceAvatar`
/// already keeps. `AppProvider` warms every visible post's cover from the same
/// data that produced the card, so the bytes are usually decoded by the time
/// this builds and a fade would be a transition over nothing. A genuinely cold
/// image sits on a flat tone: a spinner says "this card is still loading"
/// about a card that is finished.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url, this.extra});

  final String url;

  /// Total photo count, when there is more than one.
  final int? extra;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ClipRRect(
      borderRadius: AppRadius.mdAll,
      child: SizedBox(
        width: ListingCard._thumb,
        height: ListingCard._thumb,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              fadeInDuration: Duration.zero,
              fadeOutDuration: Duration.zero,
              placeholderFadeInDuration: Duration.zero,
              placeholder: (_, __) => Container(color: c.surfaceSunken),
              errorWidget: (_, __, ___) => Container(
                color: c.surfaceSunken,
                child: Icon(AppIcons.imageBroken,
                    color: c.contentTertiary, size: 22),
              ),
            ),
            // The photo count used to be its own row with its own icon. It is
            // a property of the photo, so it lives on the photo.
            if (extra != null)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
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
