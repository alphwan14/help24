import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/theme/app_theme.dart';
import 'package:help24/theme/tokens.dart';
import 'package:help24/theme/system_bars.dart';

/// THE SYSTEM BARS HAVE ONE OWNER, AND IT NEVER LEAVES A FIELD NULL.
///
/// WHAT WENT WRONG
/// ---------------
/// Measured on a Galaxy S20+ (Android 13, light theme, 3-button navigation) by
/// reading the framebuffer: the status bar was #0A0A0A with #030303 clock
/// glyphs — a contrast ratio of 1.0:1 — and the navigation glyphs were #E6E6E6
/// on the app's #FFFFFF bottom bar, 1.25:1. The time, battery, notification
/// icons and the back button were all invisible. Android Settings on the same
/// device, same theme, same navigation mode, showed #F6F6F6 on both bars.
///
/// Two independent causes, both about ownership rather than colour:
///
///   1. Nothing re-declared the bars. `RenderView._updateSystemChrome` returns
///      early when it finds no [AnnotatedRegion] under the screen corners, so
///      the LAST screen to declare a style kept the bars for the rest of the
///      process. The launch splash and the signed-out screen each won that
///      race at different times.
///   2. The styles that won left fields null. A null is not "inherit"; the
///      Android embedding skips null entries, so the value falls through to
///      `android:statusBarColor` in styles.xml — the brand-dark splash colour.
///
/// These tests pin both: every style is total, and the one owner is still the
/// only thing declaring bars app-wide.
void main() {
  const styles = <String, SystemUiOverlayStyle>{
    'light': SystemBars.light,
    'dark': SystemBars.dark,
    'splash': SystemBars.splash,
    'immersive': SystemBars.immersive,
  };

  /// Every .dart file under lib/, as (filename, source).
  List<MapEntry<String, String>> libSources() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => MapEntry(f.uri.pathSegments.last, f.readAsStringSync()))
      .toList();

  group('every style is total — no field may be null', () {
    styles.forEach((name, style) {
      test('$name leaves nothing to fall through to styles.xml', () {
        expect(style.statusBarColor, isNotNull,
            reason: 'a null status bar colour is exactly how the invisible '
                'clock happened: it falls through to the brand-dark window');
        expect(style.statusBarIconBrightness, isNotNull);
        expect(style.statusBarBrightness, isNotNull);
        expect(style.systemStatusBarContrastEnforced, isNotNull);
        expect(style.systemNavigationBarColor, isNotNull);
        expect(style.systemNavigationBarDividerColor, isNotNull);
        expect(style.systemNavigationBarIconBrightness, isNotNull);
        expect(style.systemNavigationBarContrastEnforced, isNotNull);
      });
    });
  });

  group('icons contrast against the bar they sit on', () {
    test('light theme paints a light field and asks for dark icons', () {
      expect(SystemBars.light.statusBarColor, AppTheme.lightBackground);
      expect(SystemBars.light.statusBarIconBrightness, Brightness.dark);
      expect(SystemBars.light.systemNavigationBarColor, AppTheme.lightSurface);
      expect(
          SystemBars.light.systemNavigationBarIconBrightness, Brightness.dark);
    });

    test('dark theme is the same construction, inverted', () {
      expect(SystemBars.dark.statusBarColor, AppTheme.darkBackground);
      expect(SystemBars.dark.statusBarIconBrightness, Brightness.light);
      expect(SystemBars.dark.systemNavigationBarColor, AppTheme.darkSurface);
      expect(
          SystemBars.dark.systemNavigationBarIconBrightness, Brightness.light);
    });

    test('the deliberately dark styles ask for light icons', () {
      for (final style in [SystemBars.splash, SystemBars.immersive]) {
        expect(style.statusBarIconBrightness, Brightness.light);
        expect(style.systemNavigationBarIconBrightness, Brightness.light);
      }
    });

    test('the bar colour tracks the surface the app actually paints', () {
      // The bottom bar is what CustomBottomNav paints and the status bar sits
      // over the scaffold field. If either drifts from the style SystemBars
      // declares, a seam appears along the top or bottom of every screen.
      //
      // ASSERTED AGAINST THE BUILT THEME, not the source text. It used to be a
      // regex over app_theme.dart because constructing a ThemeData called
      // GoogleFonts.poppinsTextTheme(), which fetched Poppins over the network
      // and threw in a unit test. The typeface is bundled now, so the real
      // object is reachable — and a source regex could only ever pin the
      // SPELLING of a colour, which is exactly what let the seam below through:
      // a refactor that moved the bar to a differently-named token kept every
      // constant intact and still broke the contract.
      for (final (theme, bars, colors) in [
        (AppTheme.lightTheme, SystemBars.light, AppColors.light),
        (AppTheme.darkTheme, SystemBars.dark, AppColors.dark),
      ]) {
        expect(theme.scaffoldBackgroundColor, bars.statusBarColor,
            reason: 'the status bar sits over the scaffold field');
        expect(colors.navSurface, bars.systemNavigationBarColor,
            reason: 'AppColors.navSurface IS the system navigation bar colour '
                '— that is the whole reason the token exists');
        expect(theme.bottomNavigationBarTheme.backgroundColor,
            bars.systemNavigationBarColor,
            reason: 'the bottom bar must meet the navigation bar exactly');
      }
      expect(SystemBars.light.statusBarColor, AppTheme.lightBackground);
      expect(SystemBars.dark.statusBarColor, AppTheme.darkBackground);
      expect(SystemBars.light.systemNavigationBarColor, AppTheme.lightSurface);
      expect(SystemBars.dark.systemNavigationBarColor, AppTheme.darkSurface);
    });

    test('CustomBottomNav paints navSurface, never surface', () {
      // The seam this file exists to prevent came back for exactly this
      // reason: `surface` and the system navigation bar agree in light and
      // differ by one step in dark, so a bar painted with `surface` looks
      // correct in the theme it was checked in.
      final src = File('lib/widgets/custom_bottom_nav.dart').readAsStringSync();
      expect(src, contains('color: c.navSurface'));
    });
  });

  group('forBrightness resolves the app theme, not the platform', () {
    test('it maps both brightnesses', () {
      expect(SystemBars.forBrightness(Brightness.light), SystemBars.light);
      expect(SystemBars.forBrightness(Brightness.dark), SystemBars.dark);
    });
  });

  group('an AppBar must not disagree with the root owner', () {
    // 26 screens build an AppBar, and an AppBar declares its OWN annotation.
    // Left at the Material default it punches a transparent status bar through
    // to the brand-dark window background — the original bug in a new hat. The
    // theme pins it to the same style the root declares.
    test('both themes pin appBarTheme.systemOverlayStyle', () {
      // Asserted on the built theme now that the typeface is bundled. The old
      // regex required the literal `const AppBarTheme(systemOverlayStyle: ...)`
      // spelling, so it failed the moment the two themes were built from one
      // function — while the guarantee it describes was still intact.
      for (final (theme, bars, name) in [
        (AppTheme.lightTheme, SystemBars.light, 'light'),
        (AppTheme.darkTheme, SystemBars.dark, 'dark'),
      ]) {
        expect(
          theme.appBarTheme.systemOverlayStyle,
          bars,
          reason: 'the $name AppBar must declare the same bars as the root '
              'owner, or the 26 screens that build one disagree with the rest '
              'of the app',
        );
        expect(theme.appBarTheme.backgroundColor, bars.statusBarColor,
            reason: 'an AppBar sits directly under the status bar');
      }
    });
  });

  group('the ownership itself', () {
    testWidgets('SystemBars declares the bars for whatever it wraps',
        (tester) async {
      await tester.pumpWidget(const SystemBars(
        brightness: Brightness.light,
        child: SizedBox.shrink(),
      ));
      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.byType(AnnotatedRegion<SystemUiOverlayStyle>));
      expect(region.value, SystemBars.light);
    });

    test('nothing outside the owner and the splash declares system bars', () {
      final declarers = libSources()
          .where(
              (e) => e.value.contains('AnnotatedRegion<SystemUiOverlayStyle>'))
          .map((e) => e.key)
          .toList()
        ..sort();
      expect(
        declarers,
        ['launch_splash.dart', 'system_bars.dart'],
        reason: 'a screen that declares its own bars keeps them after it is '
            'popped — that is the defect this file exists to prevent',
      );
    });

    test('no file reaches for the constants that hard-code a black nav bar',
        () {
      // SystemUiOverlayStyle.light and .dark BOTH set
      // systemNavigationBarColor: Color(0xFF000000) and no statusBarColor at
      // all. The signed-out screen used one, which is how a light-theme app
      // ended up with a black navigation bar.
      final offenders = libSources()
          .where((e) => e.key != 'system_bars.dart') // documents them
          .where((e) =>
              e.value.contains('SystemUiOverlayStyle.light') ||
              e.value.contains('SystemUiOverlayStyle.dark'))
          .map((e) => e.key)
          .toList();
      expect(offenders, isEmpty);
    });

    test('main.dart no longer writes the bars imperatively', () {
      final src = File('lib/main.dart').readAsStringSync();
      expect(src.contains('setSystemUIOverlayStyle'), isFalse,
          reason: 'an imperative call loses to any AnnotatedRegion mounted at '
              'the time, and is silently dropped when none is');
      expect(src.contains('SystemBars('), isTrue);
    });
  });
}

// `_themeBlocks` lived here: a source-scraping helper that existed because
// building a ThemeData used to call `GoogleFonts.poppinsTextTheme()`, which
// fetched a font over the network and threw under flutter_test. Inter is
// bundled in assets now, so neither the problem nor the workaround survives —
// and the tests above stopped calling it when the palette moved to tokens.
