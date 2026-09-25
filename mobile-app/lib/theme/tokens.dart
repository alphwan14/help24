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
