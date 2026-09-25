import 'package:flutter/material.dart';
import 'system_bars.dart';
import 'tokens.dart';

/// The two `ThemeData`s, built from [AppColors] and [AppTypeScale].
///
/// ── Why the flat statics below still exist ──────────────────────────────
/// There are **~645 references** to `AppTheme.primaryAccent` (285),
/// `successGreen` (151), `errorRed` (108) and `warningOrange` (101) across the
/// app. Repointing those five constants is what lets the entire product
/// re-tone in one commit, with zero call-site edits and a one-file revert.
///
/// They are TRANSITIONAL SHIMS. A `const Color` cannot be brightness-aware,
/// and that limitation is the whole reason [AppColors] exists: measured across
/// the amber ramp, **no single value clears 4.5:1 as text on light paper AND
/// on a dark card**. So each shim below is tuned to pass AA on light (the
/// design target) while clearing 3:1 on dark, which is strictly better than
/// every value it replaces — four of the old five failed AA outright:
///
///     token             old        ratio (light)   new        ratio (light)
///     primaryAccent     #6265F0    4.53 (0.03 sp)  #96620A    5.19
///     successGreen      #10B981    2.54  FAIL      #0B7A4B    5.39
///     warningOrange     #F59E0B    2.15  FAIL      #A8541A    5.32
///     errorRed          #EF4444    3.76  FAIL      #D13A2F    4.82
///     lightTextTertiary #9CA3AF    2.54  FAIL      #686F77    5.09
///
/// New code reads `AppColors.of(context)`. As components migrate, these
/// shrink; when the last reference goes, so do they.
class AppTheme {
  // ── Brand ─────────────────────────────────────────────────────────────
  // Straight off `branding/help24-mark.svg`. These two ARE Help24.
  static const Color brandInk = Color(0xFF12161A);
  static const Color brandAmber = Color(0xFFE8A33D);

  // ── Dark surfaces ─────────────────────────────────────────────────────
  static const Color darkBackground = Color(0xFF0E1114);
  static const Color darkSurface = Color(0xFF15191D);
  static const Color darkCard = Color(0xFF1B2024);
  static const Color darkCardHover = Color(0xFF232930);
  static const Color darkBorder = Color(0xFF2A3035);

  // ── Light surfaces ────────────────────────────────────────────────────
  // `lightBackground` is now WARM paper, matching the brand lockup, not the
  // cool `#F8F9FA` it used to be.
  static const Color lightBackground = Color(0xFFFAF9F7);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFE3E0D9);

  // ── Accents (shims — see the class doc) ───────────────────────────────
  /// Deep brand amber. Legible as text on light (5.19:1) and as a fill under
  /// white (5.19:1). NOT the primary button any more — that is ink, and it
  /// comes from the button themes below so it can differ per brightness.
  static const Color primaryAccent = Color(0xFF96620A);

  /// Was cyan `#22D3EE`, which measured 1.81:1 on white and made anything
  /// defaulting to `ColorScheme.secondary` invisible. Now the brand crossbar.
  static const Color secondaryAccent = Color(0xFFE8A33D);

  static const Color successGreen = Color(0xFF0B7A4B);

  /// Terracotta, not gold — deliberately. Now that the brand accent is amber,
  /// a caution chip in amber would be indistinguishable from a selected state.
  static const Color warningOrange = Color(0xFFA8541A);

  static const Color errorRed = Color(0xFFD13A2F);

  /// Informational — links, and the listing-type badge. Was Material 2014's
  /// `#2196F3`, which arrived with the type badges and matched nothing else.
  static const Color infoBlue = Color(0xFF1F5FBF);

  // ── Text ──────────────────────────────────────────────────────────────
  static const Color darkTextPrimary = Color(0xFFF2F4F6);
  static const Color darkTextSecondary = Color(0xFFA8B0B8);
  static const Color darkTextTertiary = Color(0xFF868E96);

  static const Color lightTextPrimary = Color(0xFF12161A);
  static const Color lightTextSecondary = Color(0xFF585F66);
  static const Color lightTextTertiary = Color(0xFF686F77);

  static ThemeData get lightTheme => _build(AppColors.light, Brightness.light);
  static ThemeData get darkTheme => _build(AppColors.dark, Brightness.dark);

  /// One builder, two palettes. The themes cannot drift apart because there
  /// is only one description of what a theme IS — which is why every widget
  /// should stop writing `isDark ? X : Y` and read `AppColors.of(context)`.
  static ThemeData _build(AppColors c, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final textTheme =
        AppTypeScale.textTheme(c.contentPrimary, c.contentSecondary);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: AppTypeScale.family,
      scaffoldBackgroundColor: c.page,
      canvasColor: c.surface,
      primaryColor: c.contentPrimary,

      colorScheme: ColorScheme(
        brightness: brightness,
        // The ONE action. Material's defaults (FilledButton, focus rings,
        // selection handles) all key off `primary`, so making it ink is what
        // gives the whole app a single high-contrast primary action for free.
        primary: c.actionFill,
        onPrimary: c.contentOnAction,
        // The brand accent. A FILL — always paired with ink on top.
        secondary: c.accentFill,
        onSecondary: c.contentOnAccent,
        error: c.criticalFill,
        onError: Colors.white,
        surface: c.surface,
        onSurface: c.contentPrimary,
        surfaceContainerHighest: c.surfaceSunken,
        outline: c.borderStrong,
        outlineVariant: c.borderHairline,
      ),

      textTheme: textTheme,

      appBarTheme: AppBarTheme(
        systemOverlayStyle: isDark ? SystemBars.dark : SystemBars.light,
        backgroundColor: c.page,
        foregroundColor: c.contentPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: c.contentPrimary, size: 24),
        titleTextStyle: AppTypeScale.headingM.copyWith(
          fontFamily: AppTypeScale.family,
          color: c.contentPrimary,
        ),
      ),

      // Sizes stay literal here to avoid an import cycle with app_icons.dart,
      // which owns AppIconSize and already imports this file.
      iconTheme: IconThemeData(color: c.contentSecondary, size: 20),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: c.navSurface,
        selectedItemColor: c.contentPrimary,
        unselectedItemColor: c.contentTertiary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),

      // Border, no shadow. See AppElevation.
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.lgAll,
          side: BorderSide(color: c.borderHairline),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceSunken,
        hintStyle: AppTypeScale.bodyM.copyWith(
          fontFamily: AppTypeScale.family,
          color: c.contentTertiary,
        ),
        border: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: c.borderHairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: c.borderHairline),
        ),
        // The focus ring is a real affordance, so it takes the highest
        // contrast colour in the theme rather than a tint.
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: c.contentPrimary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: c.criticalFill),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: c.criticalFill, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpace.lg,
          vertical: AppSpace.md + 2,
        ),
      ),

      // 48 px — Material 3's minimum touch target, applied to the primary
      // control rather than left to whatever padding happened to be typed.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: c.actionFill,
          foregroundColor: c.contentOnAction,
          disabledBackgroundColor: c.surfaceSunken,
          disabledForegroundColor: c.contentTertiary,
          elevation: 0,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
          textStyle: AppTypeScale.label.copyWith(
            fontFamily: AppTypeScale.family,
            fontSize: 15,
          ),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.actionFill,
          foregroundColor: c.contentOnAction,
          disabledBackgroundColor: c.surfaceSunken,
          disabledForegroundColor: c.contentTertiary,
          elevation: 0,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
          textStyle: AppTypeScale.label.copyWith(
            fontFamily: AppTypeScale.family,
            fontSize: 15,
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.contentPrimary,
          // 3.30:1 — this outline is the only thing saying the control is
          // there, so it has to meet the non-text contrast rule.
          side: BorderSide(color: c.borderStrong),
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
          textStyle: AppTypeScale.label.copyWith(
            fontFamily: AppTypeScale.family,
            fontSize: 15,
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.contentPrimary,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.smAll),
          textStyle: AppTypeScale.label.copyWith(
            fontFamily: AppTypeScale.family,
            fontSize: 15,
          ),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: c.surfaceSunken,
        selectedColor: c.accentFill,
        labelStyle: AppTypeScale.label.copyWith(
          fontFamily: AppTypeScale.family,
          color: c.contentPrimary,
        ),
        secondaryLabelStyle: AppTypeScale.label.copyWith(
          fontFamily: AppTypeScale.family,
          color: c.contentOnAccent,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
        ),
        side: BorderSide(color: c.borderHairline),
      ),

      dividerTheme: DividerThemeData(color: c.borderHairline, thickness: 1),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
        titleTextStyle: AppTypeScale.headingM.copyWith(
          fontFamily: AppTypeScale.family,
          color: c.contentPrimary,
        ),
        contentTextStyle: AppTypeScale.bodyM.copyWith(
          fontFamily: AppTypeScale.family,
          color: c.contentSecondary,
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.contentPrimary,
        contentTextStyle: AppTypeScale.bodyM.copyWith(
          fontFamily: AppTypeScale.family,
          color: c.page,
        ),
        actionTextColor: c.accentFill,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        elevation: 0,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.contentPrimary,
        linearTrackColor: c.surfaceSunken,
        circularTrackColor: c.surfaceSunken,
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: c.contentPrimary,
        inactiveTrackColor: c.surfaceSunken,
        thumbColor: c.contentPrimary,
        overlayColor: c.contentPrimary.withValues(alpha: 0.08),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return c.contentOnAction;
          return c.surface;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return c.actionFill;
          return c.borderStrong;
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),

      // The palette itself, so `AppColors.of(context)` works anywhere below
      // the MaterialApp — and so a theme switch INTERPOLATES rather than
      // snapping.
      extensions: <ThemeExtension<dynamic>>[c],
    );
  }
}
