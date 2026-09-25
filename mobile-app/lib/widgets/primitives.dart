import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// THE HELP24 PRIMITIVES.
///
/// Four widgets that every surface is built from, so a screen stops inventing
/// its own decoration. They are deliberately small and unopinionated about
/// content — the job here is to end the drift, not to encode any one screen's
/// layout.
///
/// ── What each of these replaces ─────────────────────────────────────────
///   [AppChip]    ~6 bespoke pill implementations (`_SmallTag`, `_StatusBadge`,
///                `_CategoryBadge`, `_SponsoredTag`, `_RequestTakenChip`, and
///                inline `Container`s), at 4 different heights and radii.
///   [AppCard]    the fill + 1 px border + drop-shadow stack that every card
///                carried. A surface gets a border OR a shadow, never both.
///   [AppRow]     the 74 px `_SettingsTile` with its decorative tinted icon
///                square and its explanatory subtitle.
///   [SectionHeader]  section labels typed out at each call site.
///
/// Nothing here is wired into a screen yet. They are added BESIDE the existing
/// widgets so each surface can adopt them one at a time and be verified on
/// device before the old one is deleted.

// ─────────────────────────────────────────────────────────────────────────
// CHIP
// ─────────────────────────────────────────────────────────────────────────

/// What a chip MEANS. Colour follows from this and is never passed in.
///
/// Passing a raw `Color` is how the old `_SmallTag` ended up rendering a
/// `Soon` tag in `#FF9800` beside a `Payment Protected` tag in `#F59E0B` — two
/// ambers, two pixels apart, on one card.
enum ChipTone {
  /// The default, and what most chips should be. Context, not status:
  /// a category, an answer, a count.
  neutral,

  /// The brand moment. Selection only — never a status.
  accent,

  /// Money settled, work completed, available now.
  positive,

  /// Soon, pending, funds held. Terracotta, not gold — see [AppColors].
  caution,

  /// Urgent, disputed, expired.
  critical,

  /// Informational.
  info,
}

enum ChipSize {
  /// In-card tags. The dense one.
  sm,

  /// Standalone controls.
  md,
}

/// One chip. One height per size, one radius, one way to be coloured.
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    this.icon,
    this.tone = ChipTone.neutral,
    this.size = ChipSize.sm,
    this.solid = false,
  });

  final String label;
  final IconData? icon;
  final ChipTone tone;
  final ChipSize size;

  /// Filled with the tone's full-strength colour instead of its tint. Reserve
  /// this for the ONE chip on a surface that has to be seen first — a live
  /// countdown, a dispute. A screen with two solid chips has none.
  final bool solid;

  double get _height => size == ChipSize.sm ? 24 : 32;
  double get _hPad => size == ChipSize.sm ? AppSpace.sm : AppSpace.md;
  double get _iconSize => size == ChipSize.sm ? 13 : 16;

  ({Color bg, Color fg}) _colors(AppColors c) {
    if (solid) {
      return switch (tone) {
        ChipTone.neutral => (bg: c.contentPrimary, fg: c.contentOnAction),
        ChipTone.accent => (bg: c.accentFill, fg: c.contentOnAccent),
        ChipTone.positive => (bg: c.positiveFill, fg: Colors.white),
        ChipTone.caution => (bg: c.cautionFill, fg: Colors.white),
        ChipTone.critical => (bg: c.criticalFill, fg: Colors.white),
        ChipTone.info => (bg: c.infoFill, fg: Colors.white),
      };
    }
    return switch (tone) {
      ChipTone.neutral => (bg: c.neutralSubtle, fg: c.contentSecondary),
      ChipTone.accent => (bg: c.accentSubtle, fg: c.accentText),
      ChipTone.positive => (bg: c.positiveSubtle, fg: c.positiveText),
      ChipTone.caution => (bg: c.cautionSubtle, fg: c.cautionText),
      ChipTone.critical => (bg: c.criticalSubtle, fg: c.criticalText),
      ChipTone.info => (bg: c.infoSubtle, fg: c.infoText),
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = _colors(AppColors.of(context));
    return Container(
      height: _height,
      padding: EdgeInsets.symmetric(horizontal: _hPad),
      decoration: BoxDecoration(
        color: colors.bg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: _iconSize, color: colors.fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: AppTypeScale.meta.copyWith(
              fontFamily: AppTypeScale.family,
              color: colors.fg,
              fontWeight: FontWeight.w500,
              fontSize: size == ChipSize.sm ? 12 : 13,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// CARD
// ─────────────────────────────────────────────────────────────────────────

/// A surface that holds content.
///
/// ONE separation, never two. Every card in the app used to carry a white
/// fill AND a 1 px border AND a drop shadow, sitting on a grey page — three
/// devices doing one job, which is why nothing on a Help24 screen receded.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(AppSpace.lg),
    this.margin,
    this.borderColor,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final EdgeInsets? margin;

  /// Override only to mark a card as special (a sponsored slot). Everything
  /// else takes the hairline.
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: AppRadius.lgAll,
      side: BorderSide(color: borderColor ?? c.borderHairline),
    );

    return Padding(
      padding: margin ?? EdgeInsets.zero,
      // Material + InkWell rather than a decorated GestureDetector, so the
      // press feedback is clipped to the card instead of spilling onto the
      // nearest Material ancestor — which is what painted a grey block across
      // the settings list.
      child: Material(
        color: c.surface,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// ROW
// ─────────────────────────────────────────────────────────────────────────

/// One tappable row in a list of settings or destinations.
///
/// ── The subtitle rule ───────────────────────────────────────────────────
/// There is no `subtitle`. There is a [value], and it is right-aligned.
///
/// That is not a cosmetic difference. A subtitle invites a DESCRIPTION of the
/// destination — "Payout Destinations / Where your M-Pesa earnings are sent",
/// "Saved / Your shortlist of posts & providers" — nine of which shipped in a
/// row on the Profile screen, three of them reading "Sign in", which is what
/// tapping the row does anyway.
///
/// A [value] can only hold STATE: `14 active posts`, `Device Default`,
/// `English`, `Not set`. If a row has no state worth showing, it shows
/// nothing, and the title does the work — which it can, because the
/// destination explains itself the moment it opens.
class AppRow extends StatelessWidget {
  const AppRow({
    super.key,
    required this.title,
    this.icon,
    this.value,
    this.trailing,
    this.onTap,
    this.tone,
    this.showChevron = true,
  });

  final String title;

  /// The identifier, rendered as a plain glyph. Deliberately NOT a tinted
  /// rounded square: fourteen of those stacked share one tint, so they carry
  /// no information and cost 46 px of row width each.
  final IconData? icon;

  /// Current state, right-aligned. Never a description.
  final String? value;

  /// Replaces the chevron entirely (a switch, a badge, a completion ring).
  final Widget? trailing;

  final VoidCallback? onTap;

  /// Destructive or otherwise coloured rows (Sign out).
  final Color? tone;

  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final fg = tone ?? c.contentPrimary;

    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        // 56, down from 74. Material's minimum target is 48.
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: AppSpace.md,
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: tone ?? c.contentSecondary),
                const SizedBox(width: AppSpace.md),
              ],
              // THE TITLE WINS THE WIDTH ARGUMENT.
              //
              // With both sides flexible they split the row, and at 16 px
              // "Professional Profile", "Payment Number" and "Location Access"
              // all wrapped onto two lines while a short value sat beside them
              // in acres of space. The title is the thing being named, so it
              // takes what it needs; the value is capped and ellipsises.
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypeScale.bodyL.copyWith(
                    fontFamily: AppTypeScale.family,
                    fontSize: 15,
                    color: fg,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: AppSpace.sm),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 128),
                  child: Text(
                    value!,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypeScale.bodyS.copyWith(
                      fontFamily: AppTypeScale.family,
                      color: c.contentTertiary,
                    ),
                  ),
                ),
              ],
              if (trailing != null) ...[
                const SizedBox(width: AppSpace.sm),
                trailing!,
              ] else if (showChevron) ...[
                const SizedBox(width: AppSpace.xs),
                Icon(Icons.chevron_right_rounded,
                    size: 20, color: c.contentTertiary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A group of [AppRow]s sharing one surface, with hairlines between them.
class AppRowGroup extends StatelessWidget {
  const AppRowGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        // Indented to the text column, so the group reads as one object
        // rather than as a stack of separate bars.
        rows.add(Padding(
          padding: const EdgeInsets.only(left: AppSpace.lg + 20 + AppSpace.md),
          child: Divider(height: 1, thickness: 1, color: c.borderHairline),
        ));
      }
      rows.add(children[i]);
    }

    return Material(
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.lgAll,
        side: BorderSide(color: c.borderHairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// SECTION HEADER
// ─────────────────────────────────────────────────────────────────────────

/// The label above a group.
///
/// Owns the space above AND below it, so a section can never be the one that
/// forgets its gap — which is exactly what happened to "Support" on the
/// Profile screen, where a missing `SizedBox` left one heading hard against
/// the card above it while every other heading had air.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSpace.section,
        bottom: AppSpace.md,
        left: AppSpace.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: AppTypeScale.label.copyWith(
                fontFamily: AppTypeScale.family,
                color: c.contentTertiary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A dot-separated line of context — `Request · Plumbing · Leak · Toilet`.
///
/// This is what replaces a row of identical chips. On the live feed a single
/// card rendered the category badge and two Smart Posting highlight answers as
/// three visually IDENTICAL pills, so nothing told the reader which one was
/// the category and which two were answers. As text, the order carries that
/// meaning for free, it costs one line instead of three chip heights, and it
/// stops competing with the chips that do signal status.
class MetaLine extends StatelessWidget {
  const MetaLine(this.parts, {super.key, this.leadingIcon});

  final List<String> parts;
  final IconData? leadingIcon;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final visible = parts.where((p) => p.trim().isNotEmpty).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return Row(
      children: [
        if (leadingIcon != null) ...[
          Icon(leadingIcon, size: 13, color: c.contentTertiary),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Text(
            visible.join('  ·  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypeScale.meta.copyWith(
              fontFamily: AppTypeScale.family,
              color: c.contentTertiary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Money. Always tabular, always the same weight, never green.
///
/// The price used to render in `successGreen`, which measured **2.54:1** on
/// white — the least readable colour in the app on the most important number
/// on the card — and which put a second saturated element next to the CTA.
/// Green now means *settled*, not *costs*.
class MoneyLabel extends StatelessWidget {
  const MoneyLabel(this.label, {super.key, this.muted = false});

  final String label;

  /// For "Open to offers" — the ABSENCE of a price is not a price.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTypeScale.mono.copyWith(
        fontFamily: AppTypeScale.family,
        color: muted ? c.contentSecondary : c.contentPrimary,
        fontWeight: muted ? FontWeight.w400 : FontWeight.w600,
        fontSize: 15,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// SHEET HANDLE
// ─────────────────────────────────────────────────────────────────────────

/// The grab bar at the top of a bottom sheet.
///
/// ── Why this is a widget ────────────────────────────────────────────────
/// It was written by hand FOURTEEN times — in the composer, the filter sheet,
/// the application modal, both location sheets, the chat sheet, three profile
/// sheets, the auth sheet, the dispute sheet and the permission explainer. The
/// copies had drifted to two widths (36 and 40), three different colours and
/// eight different margins, so no two sheets in the app opened with quite the
/// same affordance.
///
/// ── The contrast bug the copies shared ──────────────────────────────────
/// Twelve of them drew the bar in the HAIRLINE border colour, which is
/// `#E3E0D9` on white — **1.29:1**. A hairline is meant to be a boundary you
/// do not notice; this is a control, and the only thing on the screen saying
/// "this sheet can be dragged away". It was effectively invisible in light
/// mode, which is the same failure as the empty state whose icon box sat at
/// 1.05:1 on the page it existed to fill.
///
/// It is [AppColors.borderStrong] now — 3.30:1, the threshold for a non-text
/// element that carries meaning.
class SheetHandle extends StatelessWidget {
  const SheetHandle({
    super.key,
    this.margin =
        const EdgeInsets.only(top: AppSpace.md, bottom: AppSpace.sm),
  });

  /// Space around the handle. The only thing a caller may vary, and most
  /// should not: sheets that already pad their own top pass [EdgeInsets.zero],
  /// everything else takes the default.
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: margin,
        decoration: BoxDecoration(
          color: AppColors.of(context).borderStrong,
          borderRadius: AppRadius.pillAll,
        ),
        // Announced, because a drag handle is a control. Screen-reader users
        // reached these sheets and found an unlabelled 4 px box.
        child: Semantics(
          label: 'Drag to dismiss',
          container: true,
          child: const SizedBox.shrink(),
        ),
      ),
    );
  }
}
