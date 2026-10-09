import 'package:flutter/material.dart';

/// THE HELP24 TOKEN LAYER.
///
/// ── Why this file exists ────────────────────────────────────────────────
/// Before this, a colour was picked at the call site. `grep` found **39
/// distinct hard-coded hex values** across 13 files, plus `Colors.red` ×13
/// and `Colors.grey` ×5 — Material constants that do not change between light
/// and dark at all. Red, amber and green were each defined TWICE and both
/// definitions rendered on the same feed card: a `Soon` tag in `#FF9800` beside
/// a `Payment Protected` tag in `#F59E0B`.
///
/// Radius was worse: **19 distinct values** (1, 2, 3, 4, 6, 8, 9, 10, 11, 12,
/// 14, 15, 16, 18, 20, 22, 24, 26, 50) across 323 call sites.
///
/// ── The palette is the BRAND's, not a new one ───────────────────────────
/// Help24 already had an identity and the app was not using it. The brand
/// marks in `branding/*.svg` contain exactly three colours:
///
///     #12161A  ink    — the `|–|` bars, and the launcher icon background
///     #E8A33D  amber  — the crossbar. THE brand accent.
///     #F5F3EF  paper  — the warm off-white of the lockup
///
/// The app shipped `#6265F0` indigo and `#22D3EE` cyan on a COOL grey. Nothing
/// in the brand is purple. On the auth sheet you could watch the collision:
/// the black-and-amber logo sitting directly above a full-width indigo button.
///
/// ── Why the primary ACTION is ink, not amber ────────────────────────────
/// Amber cannot carry text on white (`#E8A33D` measures 2.16:1). That
/// constraint is a gift: it forces the correct structure rather than letting
/// us bolt accessibility on afterwards.
///
///   • the ACTION is ink on white / near-white on dark — 18.2:1 and 17.2:1.
///     One unmistakable primary action per screen, no hue spent.
///   • the ACCENT is amber, used to mark SELECTION and brand moments, where
///     it is always paired with ink on top (8.4:1).
///
/// ── Why AppColors is brightness-resolved and the old statics are not ────
/// `AppTheme.primaryAccent` was a single `const` serving four different jobs
/// at once: button fill, accent text, active marker, and tint source. It was
/// asked to be legible in BOTH themes, and no colour can do that here —
/// measured, across the whole amber ramp, not one value clears 4.5:1 as text
/// on light paper AND on a dark card. That is why this extension resolves per
/// brightness and the legacy statics in `app_theme.dart` survive only as
/// transitional shims.
///
/// ── FILL and TEXT are different tokens. This is the whole fix. ──────────
/// The old palette's root fault was using Tailwind FILL colours as FOREGROUND
/// colours. `#10B981` is a fine green to fill a shape with; as text on white
/// it measures 2.54:1 — and it was the colour of the PRICE. Every semantic
/// role below therefore carries three values: `Text` (legible), `Fill` (a
/// solid a chip or indicator is made of) and `Subtle` (the tint behind it).
///
/// ── Every number in this file was measured, not chosen by eye ───────────
/// Contrast is WCAG 2.1: 4.5:1 for normal text, 3:1 for large text and for
/// non-text boundaries. Ratios are noted per token. If you change a value,
/// re-measure it — do not eyeball it.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.page,
    required this.surface,
    required this.surfaceSunken,
    required this.surfaceRaised,
    required this.navSurface,
    required this.contentPrimary,
    required this.contentSecondary,
    required this.contentTertiary,
    required this.borderHairline,
    required this.borderStrong,
    required this.actionFill,
    required this.contentOnAction,
    required this.accentFill,
    required this.accentText,
    required this.accentSubtle,
    required this.contentOnAccent,
    required this.positiveText,
    required this.positiveFill,
    required this.positiveSubtle,
    required this.cautionText,
    required this.cautionFill,
    required this.cautionSubtle,
    required this.criticalText,
    required this.criticalFill,
    required this.criticalSubtle,
    required this.infoText,
    required this.infoFill,
    required this.infoSubtle,
    required this.neutralSubtle,
  });

  // ── Surfaces ──────────────────────────────────────────────────────────
  /// The ground the whole app stands on. Cards sit ON this.
  final Color page;

  /// Cards, sheets, dialogs — the paper content is printed on.
  final Color surface;

  /// Recessed: text inputs, unselected chips. Reads as "below" [surface].
  final Color surfaceSunken;

  /// Pressed / hovered / selected row.
  final Color surfaceRaised;

  /// THE COLOUR ANDROID PAINTS THE SYSTEM NAVIGATION BAR.
  ///
  /// The bottom bar sits directly against it, so if the two disagree a seam
  /// appears along the bottom of every screen in the app. That is not
  /// hypothetical: this token exists because a token refactor moved the bar to
  /// `surface` and left the system bar on its own value, and
  /// `system_bars_test` caught the 1B2024-against-15191D gap before it shipped.
  ///
  /// It is therefore DEFINED as `SystemBars.<theme>.systemNavigationBarColor`
  /// and pinned to it by that test. Anything that paints the bottom bar reads
  /// this, never `surface`.
  final Color navSurface;

  // ── Content ───────────────────────────────────────────────────────────
  /// Titles, values, anything that must be read first.
  final Color contentPrimary;

  /// Supporting text that is still meant to be read.
  final Color contentSecondary;

  /// Timestamps, captions, meta. REPLACES the old `#9CA3AF`, which measured
  /// 2.54:1 on white and failed AA *and* AA-large while carrying every
  /// timestamp, every card description and every schema answer in the app.
  final Color contentTertiary;

  // ── Boundaries ────────────────────────────────────────────────────────
  /// Felt, not seen. Separation between rows and around cards. Deliberately
  /// low contrast — it is not carrying information.
  final Color borderHairline;

  /// SEEN. The outline of a control whose boundary is the only thing saying
  /// it is there (a secondary button on white). WCAG asks 3:1 of anything
  /// doing that job, which is why this is a mid grey and not a tasteful
  /// hairline that disappears in use.
  final Color borderStrong;

  // ── The one action ────────────────────────────────────────────────────
  /// The primary button. Ink on light, near-white on dark — so "one
  /// high-contrast action" holds in both themes without a second design
  /// language. 18.2:1 / 17.2:1 against [contentOnAction].
  final Color actionFill;

  /// The label on [actionFill].
  final Color contentOnAction;

  // ── Brand accent ──────────────────────────────────────────────────────
  /// `#E8A33D` in both themes — the brand crossbar, unaltered. A FILL only:
  /// it marks selection and brand moments and always carries
  /// [contentOnAccent] on top (8.4:1). Never set text in this on light.
  final Color accentFill;

  /// Amber that is legible as TEXT in *this* theme. Light darkens it to
  /// `#96620A` (5.2:1); dark can use the brand value directly (7.6:1).
  final Color accentText;

  /// The tint behind an accent chip.
  final Color accentSubtle;

  /// The label on [accentFill]. Always ink — amber is a light colour.
  final Color contentOnAccent;

  // ── Semantic roles ────────────────────────────────────────────────────
  // Money, completed, paid out.
  final Color positiveText;
  final Color positiveFill;
  final Color positiveSubtle;

  // Soon, pending, payment held. NOT the brand amber: caution is shifted to
  // terracotta precisely so a status chip can never be mistaken for a
  // selected state, now that the brand accent is gold.
  final Color cautionText;
  final Color cautionFill;
  final Color cautionSubtle;

  // Urgent, disputed, destructive.
  final Color criticalText;
  final Color criticalFill;
  final Color criticalSubtle;

  // Links, informational.
  final Color infoText;
  final Color infoFill;
  final Color infoSubtle;

  /// The tint behind a neutral chip / a quiet block.
  final Color neutralSubtle;

  /// Read the palette for the current theme.
  ///
  /// This is how every widget should get a colour. A widget must never write
  /// `isDark ? X : Y` again — that ternary is in essentially every widget file
  /// today and is exactly why the two themes drift apart.
  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>() ?? light;

  // ── LIGHT — the default, and the theme the app is DESIGNED in ─────────
  static const AppColors light = AppColors(
    page: Color(0xFFFAF9F7), //            warm paper, from the brand lockup
    surface: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFF4F2EE),
    surfaceRaised: Color(0xFFF7F5F1),
    navSurface: Color(0xFFFFFFFF), //      == SystemBars.light.systemNavigationBarColor
    contentPrimary: Color(0xFF12161A), //  18.18:1 on surface — brand ink
    contentSecondary: Color(0xFF585F66), // 6.47:1
    contentTertiary: Color(0xFF686F77), //  5.09:1 (was 2.54:1 — a hard fail)
    borderHairline: Color(0xFFE3E0D9), //   1.32:1 — felt, not seen
    borderStrong: Color(0xFF928D83), //     3.30:1 — meets the 3:1 control rule
    actionFill: Color(0xFF12161A),
    contentOnAction: Color(0xFFFFFFFF), //  18.18:1 on actionFill
    accentFill: Color(0xFFE8A33D), //       the brand crossbar, unaltered
    accentText: Color(0xFF96620A), //       5.19:1 on surface, 4.72:1 on tint
    accentSubtle: Color(0xFFFDF3E2),
    contentOnAccent: Color(0xFF12161A), //  8.43:1 on accentFill
    positiveText: Color(0xFF0B7A4B), //     5.39:1 — THE PRICE (was 2.54:1)
    positiveFill: Color(0xFF12A365), //     3.25:1 — indicator only, never text
    positiveSubtle: Color(0xFFE8F6EF),
    cautionText: Color(0xFFA8541A), //      5.32:1 (was 2.15:1)
    cautionFill: Color(0xFFC96A22),
    cautionSubtle: Color(0xFFFBEFE6),
    criticalText: Color(0xFFC22B22), //     5.73:1 (was 3.76:1)
    criticalFill: Color(0xFFD13A2F),
    criticalSubtle: Color(0xFFFCECEA),
    infoText: Color(0xFF1F5FBF), //         6.09:1
    infoFill: Color(0xFF2E70D0),
    infoSubtle: Color(0xFFEAF1FC),
    neutralSubtle: Color(0xFFF4F2EE),
  );

  // ── DARK — the SAME design, re-toned. Not a second visual language. ───
  static const AppColors dark = AppColors(
    page: Color(0xFF0E1114),
    surface: Color(0xFF1B2024), //         cards
    surfaceSunken: Color(0xFF15191D), //   inputs, nav bar
    surfaceRaised: Color(0xFF232930),
    navSurface: Color(0xFF15191D), //      == SystemBars.dark.systemNavigationBarColor
    contentPrimary: Color(0xFFF2F4F6), //  14.90:1 on surface
    contentSecondary: Color(0xFFA8B0B8), // 7.48:1
    contentTertiary: Color(0xFF868E96), //  4.95:1 (was 3.52:1 — failed AA)
    borderHairline: Color(0xFF2A3035),
    borderStrong: Color(0xFF6E767E), //     3.56:1
    actionFill: Color(0xFFF2F4F6), //       inverts — still ONE loud action
    contentOnAction: Color(0xFF0E1114), //  17.18:1 on actionFill
    accentFill: Color(0xFFE8A33D),
    accentText: Color(0xFFE8A33D), //       7.62:1 — the brand value works here
    accentSubtle: Color(0xFF332713),
    contentOnAccent: Color(0xFF12161A), //  8.43:1
    positiveText: Color(0xFF3DD68C), //     8.76:1
    positiveFill: Color(0xFF12A365),
    positiveSubtle: Color(0xFF10291F),
    cautionText: Color(0xFFF0A46A), //      8.00:1
    cautionFill: Color(0xFFC96A22),
    cautionSubtle: Color(0xFF31260F),
    criticalText: Color(0xFFFF6B60), //     5.88:1
    criticalFill: Color(0xFFD13A2F),
    criticalSubtle: Color(0xFF331C19),
    infoText: Color(0xFF7FB0FF), //         7.47:1
    infoFill: Color(0xFF2E70D0),
    infoSubtle: Color(0xFF17243A),
    neutralSubtle: Color(0xFF232930),
  );

  @override
  AppColors copyWith({
    Color? page,
    Color? surface,
    Color? surfaceSunken,
    Color? surfaceRaised,
    Color? navSurface,
    Color? contentPrimary,
    Color? contentSecondary,
    Color? contentTertiary,
    Color? borderHairline,
    Color? borderStrong,
    Color? actionFill,
    Color? contentOnAction,
    Color? accentFill,
    Color? accentText,
    Color? accentSubtle,
    Color? contentOnAccent,
    Color? positiveText,
    Color? positiveFill,
    Color? positiveSubtle,
    Color? cautionText,
    Color? cautionFill,
    Color? cautionSubtle,
    Color? criticalText,
    Color? criticalFill,
    Color? criticalSubtle,
    Color? infoText,
    Color? infoFill,
    Color? infoSubtle,
    Color? neutralSubtle,
  }) {
    return AppColors(
      page: page ?? this.page,
      surface: surface ?? this.surface,
      surfaceSunken: surfaceSunken ?? this.surfaceSunken,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      navSurface: navSurface ?? this.navSurface,
      contentPrimary: contentPrimary ?? this.contentPrimary,
      contentSecondary: contentSecondary ?? this.contentSecondary,
      contentTertiary: contentTertiary ?? this.contentTertiary,
      borderHairline: borderHairline ?? this.borderHairline,
      borderStrong: borderStrong ?? this.borderStrong,
      actionFill: actionFill ?? this.actionFill,
      contentOnAction: contentOnAction ?? this.contentOnAction,
      accentFill: accentFill ?? this.accentFill,
      accentText: accentText ?? this.accentText,
      accentSubtle: accentSubtle ?? this.accentSubtle,
      contentOnAccent: contentOnAccent ?? this.contentOnAccent,
      positiveText: positiveText ?? this.positiveText,
      positiveFill: positiveFill ?? this.positiveFill,
      positiveSubtle: positiveSubtle ?? this.positiveSubtle,
      cautionText: cautionText ?? this.cautionText,
      cautionFill: cautionFill ?? this.cautionFill,
      cautionSubtle: cautionSubtle ?? this.cautionSubtle,
      criticalText: criticalText ?? this.criticalText,
      criticalFill: criticalFill ?? this.criticalFill,
      criticalSubtle: criticalSubtle ?? this.criticalSubtle,
      infoText: infoText ?? this.infoText,
      infoFill: infoFill ?? this.infoFill,
      infoSubtle: infoSubtle ?? this.infoSubtle,
      neutralSubtle: neutralSubtle ?? this.neutralSubtle,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      page: c(page, other.page),
      surface: c(surface, other.surface),
      surfaceSunken: c(surfaceSunken, other.surfaceSunken),
      surfaceRaised: c(surfaceRaised, other.surfaceRaised),
      navSurface: c(navSurface, other.navSurface),
      contentPrimary: c(contentPrimary, other.contentPrimary),
      contentSecondary: c(contentSecondary, other.contentSecondary),
      contentTertiary: c(contentTertiary, other.contentTertiary),
      borderHairline: c(borderHairline, other.borderHairline),
      borderStrong: c(borderStrong, other.borderStrong),
      actionFill: c(actionFill, other.actionFill),
      contentOnAction: c(contentOnAction, other.contentOnAction),
      accentFill: c(accentFill, other.accentFill),
      accentText: c(accentText, other.accentText),
      accentSubtle: c(accentSubtle, other.accentSubtle),
      contentOnAccent: c(contentOnAccent, other.contentOnAccent),
      positiveText: c(positiveText, other.positiveText),
      positiveFill: c(positiveFill, other.positiveFill),
      positiveSubtle: c(positiveSubtle, other.positiveSubtle),
      cautionText: c(cautionText, other.cautionText),
      cautionFill: c(cautionFill, other.cautionFill),
      cautionSubtle: c(cautionSubtle, other.cautionSubtle),
      criticalText: c(criticalText, other.criticalText),
      criticalFill: c(criticalFill, other.criticalFill),
      criticalSubtle: c(criticalSubtle, other.criticalSubtle),
      infoText: c(infoText, other.infoText),
      infoFill: c(infoFill, other.infoFill),
      infoSubtle: c(infoSubtle, other.infoSubtle),
      neutralSubtle: c(neutralSubtle, other.neutralSubtle),
    );
  }
}

/// THE CHAT'S OWN PALETTE.
///
/// ── Why the chat does not simply read [AppColors] ─────────────────────────
/// The approved chat redesign specifies its surfaces exactly, and several of
/// them share a NAME with an [AppColors] role while differing in value: the
/// chat ground is pure white on light (`page` is warm paper), an incoming
/// bubble is `#EEF0F2` (`surface` is white), and on dark the pinned bar sits
/// on `#15191D` where `surfaceRaised` is `#232930`. A conversation is read
/// against those exact steps — a bubble that matches the paper behind it
/// stops reading as a bubble — so the chat gets its own extension instead of
/// bending the app-wide roles to fit one screen.
///
/// ── Every value was checked, in both themes ────────────────────────────────
/// Text clears 4.5:1 and icons and progress bars clear 3:1 against the
/// surface they sit on. The outgoing bubble is the deeper amber `#80560C` in
/// BOTH themes (approved): white on it is 6.45:1, and the 78%-white meta line
/// is 4.65:1. Light and dark differ in these values ONLY — every chat
/// component's geometry is the same in both (see [ChatGeometry]), and no chat
/// component may branch on brightness.
@immutable
class ChatColors extends ThemeExtension<ChatColors> {
  const ChatColors({
    required this.bg,
    required this.surface,
    required this.surfaceRaised,
    required this.border,
    required this.text,
    required this.textSecondary,
    required this.iconSecondary,
    required this.iconDisabled,
    required this.outgoing,
    required this.onOutgoing,
    required this.onOutgoingMuted,
    required this.statusRead,
    required this.accent,
    required this.onAccent,
    required this.accentText,
    required this.progressCurrent,
    required this.progressTrack,
    required this.success,
    required this.successBar,
    required this.successTile,
    required this.warningTile,
    required this.onWarningTile,
    required this.danger,
    required this.dangerTile,
    required this.dateChipFill,
    required this.dateChipText,
    required this.mediaScrim,
    required this.onMedia,
    required this.quoteOnOutgoing,
    required this.filePage,
    required this.filePageLines,
    required this.fileBadgePdf,
    required this.fileBadgeWord,
    required this.fileBadgeOther,
    required this.onFileBadge,
    required this.mapStyle,
  });

  /// The conversation's ground.
  final Color bg;

  /// Incoming bubbles, the composer pill, the disabled send button and
  /// secondary buttons.
  final Color surface;

  /// The pinned job bar, event pills, the scroll-down button, quick replies.
  final Color surfaceRaised;

  /// Hairlines: the pinned bar's and the pills' 1 px edge.
  final Color border;

  final Color text;

  /// Incoming meta, subtitles, area lines.
  final Color textSecondary;

  /// Attach, camera and pin icons.
  final Color iconSecondary;

  /// The send arrow while there is nothing to send.
  final Color iconDisabled;

  /// Outgoing bubbles. The same in both themes.
  final Color outgoing;
  final Color onOutgoing;

  /// Time and ticks on an outgoing bubble — white at 78%.
  final Color onOutgoingMuted;

  /// Read ticks, drawn on the outgoing amber.
  final Color statusRead;

  /// Send, Directions and primary buttons — a FILL, always under [onAccent].
  final Color accent;
  final Color onAccent;

  /// Amber legible as TEXT in this theme: links, the job tile's icon.
  final Color accentText;

  final Color progressCurrent;
  final Color progressTrack;

  /// "Held" and "released" text and icons.
  final Color success;

  /// Completed progress segments.
  final Color successBar;

  /// The tile behind a success icon.
  final Color successTile;

  /// The job tile and the offline banner.
  final Color warningTile;
  final Color onWarningTile;

  /// Failed sends and disputes.
  final Color danger;
  final Color dangerTile;

  /// The day pill — translucent so a message scrolling under the pinned one
  /// is still faintly there.
  final Color dateChipFill;
  final Color dateChipText;

  /// The pill that carries the time over a photo or a map, and its label.
  /// Black at 55% under white in both themes: it sits on a picture, not on
  /// the chat ground, so it must not change with the theme.
  final Color mediaScrim;
  final Color onMedia;

  /// The quoted-reply block inside an outgoing bubble.
  final Color quoteOnOutgoing;

  /// The drawn first page of a document thumbnail, and its type strip. A
  /// document is white paper in both themes, so these do not change either.
  final Color filePage;
  final Color filePageLines;
  final Color fileBadgePdf;
  final Color fileBadgeWord;
  final Color fileBadgeOther;
  final Color onFileBadge;

  /// The Google Maps style JSON for map thumbnails and the full-screen map:
  /// null is the standard style (light), the night style on dark.
  final String? mapStyle;

  static ChatColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<ChatColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  static const ChatColors light = ChatColors(
    bg: Color(0xFFFFFFFF),
    surface: Color(0xFFEEF0F2),
    surfaceRaised: Color(0xFFF6F7F8),
    border: Color(0xFFE3E6EA),
    text: Color(0xFF14181C), //            15.62:1 on surface
    textSecondary: Color(0xFF5F6B76), //   4.77:1 on surface
    iconSecondary: Color(0xFF5F6B76),
    iconDisabled: Color(0xFFA7AFB8),
    outgoing: Color(0xFF80560C),
    onOutgoing: Color(0xFFFFFFFF), //      6.45:1
    onOutgoingMuted: Color(0xC7FFFFFF), // 4.65:1
    statusRead: Color(0xFF8FE3FF), //      4.49:1 on outgoing
    accent: Color(0xFFE5A63E),
    onAccent: Color(0xFF1A1206),
    accentText: Color(0xFF8A5A00),
    progressCurrent: Color(0xFFB87A12),
    progressTrack: Color(0xFFE3E6EA),
    success: Color(0xFF157F4B),
    successBar: Color(0xFF1F9D5F),
    successTile: Color(0xFFE3F5EB),
    warningTile: Color(0xFFFBF1DE),
    onWarningTile: Color(0xFF6B4A0E),
    danger: Color(0xFFC2392B),
    dangerTile: Color(0xFFFBE9E6),
    dateChipFill: Color(0xF0FFFFFF), //    white at 94%
    dateChipText: Color(0xFF4A545E),
    mediaScrim: Color(0x8C000000), //      black at 55%
    onMedia: Color(0xFFFFFFFF),
    quoteOnOutgoing: Color(0x2EFFFFFF),
    filePage: Color(0xFFFFFFFF),
    filePageLines: Color(0xFFC3C8CE),
    fileBadgePdf: Color(0xFFD93B3B), //    4.53:1 under white
    fileBadgeWord: Color(0xFF2B579A),
    fileBadgeOther: Color(0xFF5F6B76),
    onFileBadge: Color(0xFFFFFFFF),
    mapStyle: null,
  );

  static const ChatColors dark = ChatColors(
    bg: Color(0xFF0D1114),
    surface: Color(0xFF1B2024),
    surfaceRaised: Color(0xFF15191D),
    border: Color(0xFF232A31),
    text: Color(0xFFF2F4F5), //            14.89:1 on surface
    textSecondary: Color(0xFF9AA3AD), //   6.43:1 on surface
    iconSecondary: Color(0xFFAEB5BD),
    iconDisabled: Color(0xFF5E6670),
    outgoing: Color(0xFF80560C),
    onOutgoing: Color(0xFFFFFFFF),
    onOutgoingMuted: Color(0xC7FFFFFF),
    statusRead: Color(0xFF8FE3FF),
    accent: Color(0xFFE5A63E),
    onAccent: Color(0xFF1A1206),
    accentText: Color(0xFFE5A63E),
    progressCurrent: Color(0xFFE5A63E),
    progressTrack: Color(0xFF2B3036),
    success: Color(0xFF5FD39B),
    successBar: Color(0xFF4CC38A),
    successTile: Color(0xFF12301F),
    warningTile: Color(0xFF2A2311),
    onWarningTile: Color(0xFFF3D9A4),
    danger: Color(0xFFFF8A7A),
    dangerTile: Color(0xFF3A1A17),
    dateChipFill: Color(0xF01B2024), //    surface at 94%
    dateChipText: Color(0xFFC9CED4),
    mediaScrim: Color(0x8C000000),
    onMedia: Color(0xFFFFFFFF),
    quoteOnOutgoing: Color(0x2EFFFFFF),
    filePage: Color(0xFFFFFFFF),
    filePageLines: Color(0xFFC3C8CE),
    fileBadgePdf: Color(0xFFD93B3B),
    fileBadgeWord: Color(0xFF2B579A),
    fileBadgeOther: Color(0xFF5F6B76),
    onFileBadge: Color(0xFFFFFFFF),
    mapStyle: _nightMapStyle,
  );

  /// Google's own night style, so a map on the dark chat does not glare.
  static const String _nightMapStyle = '['
      '{"elementType":"geometry","stylers":[{"color":"#242f3e"}]},'
      '{"elementType":"labels.text.stroke","stylers":[{"color":"#242f3e"}]},'
      '{"elementType":"labels.text.fill","stylers":[{"color":"#746855"}]},'
      '{"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},'
      '{"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},'
      '{"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#263c3f"}]},'
      '{"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#6b9a76"}]},'
      '{"featureType":"road","elementType":"geometry","stylers":[{"color":"#38414e"}]},'
      '{"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#212a37"}]},'
      '{"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#9ca5b3"}]},'
      '{"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#746855"}]},'
      '{"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#1f2835"}]},'
      '{"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#f3d19c"}]},'
      '{"featureType":"transit","elementType":"geometry","stylers":[{"color":"#2f3948"}]},'
      '{"featureType":"transit.station","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},'
      '{"featureType":"water","elementType":"geometry","stylers":[{"color":"#17263c"}]},'
      '{"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#515c6d"}]},'
      '{"featureType":"water","elementType":"labels.text.stroke","stylers":[{"color":"#17263c"}]}'
      ']';

  @override
  ChatColors copyWith({String? mapStyle}) => ChatColors(
        bg: bg,
        surface: surface,
        surfaceRaised: surfaceRaised,
        border: border,
        text: text,
        textSecondary: textSecondary,
        iconSecondary: iconSecondary,
        iconDisabled: iconDisabled,
        outgoing: outgoing,
        onOutgoing: onOutgoing,
        onOutgoingMuted: onOutgoingMuted,
        statusRead: statusRead,
        accent: accent,
        onAccent: onAccent,
        accentText: accentText,
        progressCurrent: progressCurrent,
        progressTrack: progressTrack,
        success: success,
        successBar: successBar,
        successTile: successTile,
        warningTile: warningTile,
        onWarningTile: onWarningTile,
        danger: danger,
        dangerTile: dangerTile,
        dateChipFill: dateChipFill,
        dateChipText: dateChipText,
        mediaScrim: mediaScrim,
        onMedia: onMedia,
        quoteOnOutgoing: quoteOnOutgoing,
        filePage: filePage,
        filePageLines: filePageLines,
        fileBadgePdf: fileBadgePdf,
        fileBadgeWord: fileBadgeWord,
        fileBadgeOther: fileBadgeOther,
        onFileBadge: onFileBadge,
        mapStyle: mapStyle ?? this.mapStyle,
      );

  /// Interpolates, so switching theme with a chat open fades rather than
  /// snapping — the same as every other surface reading [AppColors].
  @override
  ChatColors lerp(ThemeExtension<ChatColors>? other, double t) {
    if (other is! ChatColors) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return ChatColors(
      bg: c(bg, other.bg),
      surface: c(surface, other.surface),
      surfaceRaised: c(surfaceRaised, other.surfaceRaised),
      border: c(border, other.border),
      text: c(text, other.text),
      textSecondary: c(textSecondary, other.textSecondary),
      iconSecondary: c(iconSecondary, other.iconSecondary),
      iconDisabled: c(iconDisabled, other.iconDisabled),
      outgoing: c(outgoing, other.outgoing),
      onOutgoing: c(onOutgoing, other.onOutgoing),
      onOutgoingMuted: c(onOutgoingMuted, other.onOutgoingMuted),
      statusRead: c(statusRead, other.statusRead),
      accent: c(accent, other.accent),
      onAccent: c(onAccent, other.onAccent),
      accentText: c(accentText, other.accentText),
      progressCurrent: c(progressCurrent, other.progressCurrent),
      progressTrack: c(progressTrack, other.progressTrack),
      success: c(success, other.success),
      successBar: c(successBar, other.successBar),
      successTile: c(successTile, other.successTile),
      warningTile: c(warningTile, other.warningTile),
      onWarningTile: c(onWarningTile, other.onWarningTile),
      danger: c(danger, other.danger),
      dangerTile: c(dangerTile, other.dangerTile),
      dateChipFill: c(dateChipFill, other.dateChipFill),
      dateChipText: c(dateChipText, other.dateChipText),
      mediaScrim: c(mediaScrim, other.mediaScrim),
      onMedia: c(onMedia, other.onMedia),
      quoteOnOutgoing: c(quoteOnOutgoing, other.quoteOnOutgoing),
      filePage: c(filePage, other.filePage),
      filePageLines: c(filePageLines, other.filePageLines),
      fileBadgePdf: c(fileBadgePdf, other.fileBadgePdf),
      fileBadgeWord: c(fileBadgeWord, other.fileBadgeWord),
      fileBadgeOther: c(fileBadgeOther, other.fileBadgeOther),
      onFileBadge: c(onFileBadge, other.onFileBadge),
      mapStyle: t < 0.5 ? mapStyle : other.mapStyle,
    );
  }
}

/// A PERSON WITHOUT A PHOTO STILL HAS A FACE.
///
/// The chat list used to draw every missing avatar as the same grey disc, and
/// when even the name was missing it drew "?" — so a list of eight people read
/// as eight copies of nobody. Each person now gets one of eight tints, chosen
/// from their user id (see `ChatPeople.tintIndex`), so the same person is the
/// same colour on every screen and every launch, and two people side by side
/// can be told apart before their names are read.
///
/// Muted on purpose: an avatar we do not have is not a brand moment (the
/// reason the old placeholder stopped being accent-filled). Text on every fill
/// clears 4.5:1 in its own theme.
@immutable
class PersonTint {
  const PersonTint(this.fill, this.text);

  final Color fill;
  final Color text;

  static const List<PersonTint> light = [
    PersonTint(Color(0xFFDCEFEC), Color(0xFF1F5F57)), // teal
    PersonTint(Color(0xFFDFE8F6), Color(0xFF2A4F86)), // blue
    PersonTint(Color(0xFFE8E2F4), Color(0xFF553C8A)), // violet
    PersonTint(Color(0xFFF5E1E6), Color(0xFF8A3550)), // rose
    PersonTint(Color(0xFFF6EBD7), Color(0xFF7A5413)), // amber
    PersonTint(Color(0xFFE2F0DE), Color(0xFF36612B)), // green
    PersonTint(Color(0xFFE4E8EC), Color(0xFF44505C)), // slate
    PersonTint(Color(0xFFF3E4DC), Color(0xFF85462B)), // clay
  ];

  static const List<PersonTint> dark = [
    PersonTint(Color(0xFF17302D), Color(0xFF8FD3C7)),
    PersonTint(Color(0xFF1A2638), Color(0xFF9CB9E8)),
    PersonTint(Color(0xFF261F37), Color(0xFFC2B1EA)),
    PersonTint(Color(0xFF351C25), Color(0xFFEBA6BB)),
    PersonTint(Color(0xFF33281A), Color(0xFFE5C28A)),
    PersonTint(Color(0xFF1C2D1A), Color(0xFFA9D69C)),
    PersonTint(Color(0xFF22282E), Color(0xFFB8C2CC)),
    PersonTint(Color(0xFF36231B), Color(0xFFE5AE94)),
  ];

  /// The tint at [index] for the current theme. [index] is taken modulo the
  /// palette, so any stable hash can be passed straight in.
  static PersonTint of(BuildContext context, int index) {
    final palette = Theme.of(context).brightness == Brightness.dark ? dark : light;
    return palette[index.abs() % palette.length];
  }
}

/// THE CHAT'S GEOMETRY — identical in both themes, by construction.
///
/// Sizes are the design canvas's, for a 390-wide phone, and map 1:1 to dp.
/// The radii here are component geometry, not rungs of [AppRadius]: a bubble
/// is 18 because two of them meet at 6 along a run, and that pair is the
/// bubble's shape, not a surface choice. They are named here — the one file
/// allowed to give a radius its number — rather than re-guessed per widget.
///
/// Heights below are MINIMUMS. Anything holding text grows with the system
/// text size instead of clipping it.
class ChatGeometry {
  const ChatGeometry._();

  // ── Thread ──────────────────────────────────────────────────────────────
  static const double sidePadding = 10;
  static const double textMaxWidth = 288; //   ~74% of 390
  static const double textMaxFraction = 0.74;
  static const double mediaWidth = 264; //     ~68% of 390
  static const double mediaMaxFraction = 0.68;
  static const double offerCardWidth = 272;

  /// A run: same sender, each message within this of the one before.
  static const Duration groupWindow = Duration(minutes: 2);
  static const double inGroupGap = 2;
  static const double betweenGroupsGap = 8;

  static const double bubbleRadius = 18;
  static const double bubbleJoinRadius = 6;

  // ── Text bubble ─────────────────────────────────────────────────────────
  static const EdgeInsetsDirectional textPadding =
      EdgeInsetsDirectional.fromSTEB(12, 7, 10, 7);
  static const double bodySize = 15;
  static const double bodyLine = 20;
  static const double metaSize = 11.5;
  static const double metaLine = 14;
  static const double metaGap = 6; //          text → inline time
  static const double tickSize = 14;
  static const double doubleTickWidth = 17;
  static const double statusSlotHeight = 16; // the double tick's own box

  // ── Media ───────────────────────────────────────────────────────────────
  static const double photoMinHeight = 132;
  static const double photoMaxHeight = 330;
  static const double mapHeight = 132;
  static const double mediaPillHeight = 20;
  static const double mediaPillRadius = 10;
  static const double mediaPillInset = 8;
  static const EdgeInsetsDirectional locationFooterPadding =
      EdgeInsetsDirectional.fromSTEB(10, 8, 12, 9);
  static const double pinIcon = 16;
  static const double directionsDiameter = 36;

  // ── File ────────────────────────────────────────────────────────────────
  static const EdgeInsetsDirectional filePadding =
      EdgeInsetsDirectional.fromSTEB(8, 8, 12, 8);
  static const double fileThumbWidth = 34;
  static const double fileThumbHeight = 42;
  static const double fileThumbRadius = 5;

  // ── Pills ───────────────────────────────────────────────────────────────
  static const double datePillHeight = 24;
  static const double datePillRadius = 12;
  static const double eventPillHeight = 28;
  static const double eventPillRadius = 14;

  // ── Header, bars, composer ──────────────────────────────────────────────
  static const double headerHeight = 56;
  static const double headerAvatar = 38;
  static const double jobBarRadius = 14;
  static const double jobTile = 32;
  static const double jobTileRadius = 9;
  static const double jobButtonHeight = 34;
  static const double jobButtonRadius = 17;
  static const double progressHeight = 3;
  static const double progressGap = 4;
  static const double composerHeight = 46;
  static const double composerRadius = 23;
  static const double composerIcon = 38;
  static const double sendDiameter = 46;
  static const double scrollButtonDiameter = 40;
  static const double quickReplyHeight = 34;
  static const double quickReplyRadius = 17;
  static const double bannerRadius = 12;

  /// Every control's hit area, whatever its drawn size.
  static const double minTouch = 44;
}

/// Spacing. 4 px base, one scale, one name each.
///
/// Replaces 12 distinct `EdgeInsets.all` values, two of which (11 and 26) were
/// off any grid at all. Base's rule: everything snaps to 4.
class AppSpace {
  const AppSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  /// The page gutter. 16, down from 20 — at 412 px that is 8 px more card.
  static const double gutter = 16;

  /// Between a section and the next one.
  static const double section = 24;

  /// Bottom padding a scrolling surface needs so the compose FAB never covers
  /// its last row. The FAB is 56 tall and floats 16 above the bar; 16 more
  /// keeps the last card clear of it rather than tucked underneath.
  static const double fabClearance = 88;
}

/// Radius. Five values, replacing nineteen.
class AppRadius {
  const AppRadius._();

  /// Tags, badges, small chips.
  static const double sm = 8;

  /// Buttons, inputs, thumbnails.
  static const double md = 12;

  /// Cards, sheets, dialogs.
  static const double lg = 16;

  /// The top corners of a modal surface — a bottom sheet, a dialog that
  /// arrives from the edge. Nothing else.
  ///
  /// ── Why the scale is five and not four ──────────────────────────────
  /// The audit set out to converge on four, with sheets folded into [lg].
  /// Counting the call sites said otherwise: of the 22 places that round the
  /// top of a sheet, **16 already used 24** — the app had a consistent sheet
  /// radius the whole time, it was simply never written down. Forcing those to
  /// 16 would have been 16 visible changes made to satisfy a number in a
  /// document.
  ///
  /// It is also the correct answer. A radius reads relative to the surface
  /// carrying it: 16 on a 340 px card and 16 on a full-width sheet are not the
  /// same gesture, which is why every system that has both gives the sheet a
  /// larger one (Material 3 uses 28 against 12 for cards). Four rungs was one
  /// rung short.
  static const double sheet = 24;

  /// Filter chips, capsules, avatars, drag handles, progress bars — anything
  /// whose radius is MEANT to be half its own height. See [pillAll].
  static const double pill = 999;

  // `const` fields rather than getters, so they can be used inside a `const`
  // BoxDecoration — otherwise every call site that takes one silently loses
  // its const-ness, which is the sort of tax that makes people write the
  // number instead.
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));

  /// Fully round. Use it for anything whose radius is *meant* to be half its
  /// own height — a capsule, an avatar, a 4 px drag handle, a progress bar.
  ///
  /// Those were the majority of the app's off-scale radii, and they were never
  /// really a fifth, sixth and seventh value: `circular(2)` on a 4 px bar,
  /// `circular(20)` on a 40 px avatar and `circular(50)` on a 100 px one are
  /// all one intention, written three ways, each of which silently becomes
  /// wrong the moment the element is resized. Saying `pill` says the
  /// intention, and cannot drift.
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));

  /// The one shape for the top of a modal surface.
  static const BorderRadius sheetTop =
      BorderRadius.vertical(top: Radius.circular(sheet));
}

/// Motion. One easing pair, three durations, nothing longer.
class AppMotion {
  const AppMotion._();

  /// A colour or a selection changing.
  static const Duration state = Duration(milliseconds: 120);

  /// A screen or a crossfade.
  static const Duration transition = Duration(milliseconds: 200);

  /// A sheet arriving.
  static const Duration sheet = Duration(milliseconds: 280);

  static const Curve enter = Curves.easeOut;
  static const Curve exit = Curves.easeIn;
}

/// Elevation. The rule, not a scale.
///
/// > A surface gets EITHER a border OR a shadow. Never both. Never neither.
///
/// Every card in the app currently has a fill AND a 1 px border AND a drop
/// shadow, on a grey page — three separations doing one job, which is why
/// nothing on a Help24 screen recedes. Cards take the border. Things that
/// genuinely float (sheets, menus) take the shadow.
class AppElevation {
  const AppElevation._();

  /// Sheets, menus, toasts — anything that leaves the page plane.
  ///
  /// TWO shadows, not one, and the reason is worth keeping: a tight contact
  /// shadow gives the surface an EDGE, and a wide soft one makes it read as
  /// floating ABOVE the page. One shadow can do either but not both — a single
  /// soft shadow leaves a card with no defined boundary, which in dark mode is
  /// how a `#1C1C1E` card on a `#0A0A0A` background under a black shadow
  /// became effectively invisible.
  ///
  /// The dark stack is heavier because a shadow on a near-black page has less
  /// room to darken before it stops reading at all.
  static List<BoxShadow> floating(Brightness brightness) =>
      brightness == Brightness.dark
          ? const [
              BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 28,
                  offset: Offset(0, 12)),
              BoxShadow(
                  color: Color(0x66000000), blurRadius: 6, offset: Offset(0, 2)),
            ]
          : const [
              // Tinted with the ink rather than pure black: a neutral-black
              // shadow over warm paper reads grey and slightly dirty.
              BoxShadow(
                  color: Color(0x1F12161A),
                  blurRadius: 28,
                  offset: Offset(0, 12)),
              BoxShadow(
                  color: Color(0x0F12161A), blurRadius: 5, offset: Offset(0, 2)),
            ];
}

/// Typography. Named by ROLE, never by pixel value.
///
/// ── What this replaces ──────────────────────────────────────────────────
/// Thirteen styles named `displayLarge`…`labelSmall`, which call sites then
/// ignored: `post_card.dart` alone overrode the size on nearly every text
/// node (`fontSize: 15`, `12.5`, `11.5`). The scale was advisory.
///
/// Worse, **not one style declared a line height**, so every block of copy
/// inherited Flutter's default leading and two adjacent paragraphs had
/// different effective leading by accident.
///
/// ── The scale ───────────────────────────────────────────────────────────
/// Base's construction: a 14 px base, and **line height = size × 1.45 rounded
/// to the nearest 4**, so every line box lands on the 4 px grid.
///
/// ── The typeface ────────────────────────────────────────────────────────
/// Inter, BUNDLED. The app previously called `GoogleFonts.poppinsTextTheme()`
/// with no `fonts:` section in `pubspec.yaml` and no `.ttf` in the repo —
/// which means it fetched Poppins over the NETWORK at first launch and swapped
/// fonts mid-render. On a cold install on a slow connection that swap happened
/// on the most important screen a new user will ever see.
///
/// Inter over Poppins because Poppins is a geometric DISPLAY face — circular
/// `o`, single-storey `a`, wide letterfit — and most of Help24's text lives at
/// 12–14 px, where Inter's taller x-height and open apertures hold up and
/// Poppins softens. Decisive for a marketplace: Inter has **tabular numerals**,
/// so `KSh 3,200` and `KSh 850` align in a column and a live countdown does
/// not jitter.
class AppTypeScale {
  const AppTypeScale._();

  static const String family = 'Inter';

  /// Screen titles — "Discover".
  static const TextStyle displayS =
      TextStyle(fontSize: 28, height: 40 / 28, fontWeight: FontWeight.w600, letterSpacing: -0.4);

  /// A post-detail title.
  static const TextStyle headingL =
      TextStyle(fontSize: 22, height: 32 / 22, fontWeight: FontWeight.w600, letterSpacing: -0.2);

  /// Section headings, sheet titles.
  static const TextStyle headingM =
      TextStyle(fontSize: 18, height: 28 / 18, fontWeight: FontWeight.w600, letterSpacing: -0.1);

  /// Card titles, row titles. Note w600, not w700 — display weight at small
  /// sizes reads as shouting, and Airbnb's system tops out at 500/600.
  static const TextStyle headingS =
      TextStyle(fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w600);

  /// Reading copy.
  static const TextStyle bodyL =
      TextStyle(fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w400);

  /// The default body. Deliberately NOT pre-coloured secondary — the old
  /// `bodyMedium` was, so any widget reaching for "body text" silently got
  /// grey text it never asked for.
  static const TextStyle bodyM =
      TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w400);

  static const TextStyle bodyS =
      TextStyle(fontSize: 13, height: 20 / 13, fontWeight: FontWeight.w400);

  /// Buttons, chips, nav labels.
  static const TextStyle label =
      TextStyle(fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w500);

  /// Timestamps, captions.
  static const TextStyle meta =
      TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w400);

  /// MONEY, counts, countdowns. Tabular figures so columns align and a
  /// ticking number does not shift the layout under the reader.
  static const TextStyle mono = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w500,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Map the ten roles onto Flutter's `TextTheme` slots, so every existing
  /// `Theme.of(context).textTheme.titleMedium` call site keeps working and
  /// simply gets the new value. The role names above are what new code
  /// should use.
  static TextTheme textTheme(Color primary, Color secondary) {
    TextStyle s(TextStyle base, Color c) =>
        base.copyWith(fontFamily: family, color: c);
    return TextTheme(
      displayLarge: s(displayS, primary),
      displayMedium: s(displayS, primary),
      displaySmall: s(headingL, primary),
      headlineLarge: s(headingL, primary),
      headlineMedium: s(headingL, primary), // screen titles use this today
      headlineSmall: s(headingM, primary),
      titleLarge: s(headingM, primary),
      titleMedium: s(headingS, primary), // card + row titles use this today
      titleSmall: s(label, secondary),
      bodyLarge: s(bodyL, primary),
      bodyMedium: s(bodyM, primary),
      bodySmall: s(bodyS, secondary),
      labelLarge: s(label, primary),
      labelMedium: s(label, secondary),
      labelSmall: s(meta, secondary),
    );
  }
}
