import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/theme/app_theme.dart';
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
      // The bottom bar is the app's surface colour (CustomBottomNav) and the
      // status bar sits over the scaffold field. If these drift from the theme
      // a seam appears at the top or bottom of every screen.
      //
      // Asserted against the SOURCE rather than a built ThemeData: constructing
      // one calls GoogleFonts.poppinsTextTheme(), which fetches Poppins over
      // the network and throws in a unit test (the font is not bundled). The
      // guarantee is the same — the two halves above already pin SystemBars to
      // AppTheme's constants, and this pins the themes to those same constants.
      final src = File('lib/theme/app_theme.dart').readAsStringSync();
      expect(src, contains('scaffoldBackgroundColor: lightBackground'));
      expect(src, contains('scaffoldBackgroundColor: darkBackground'));
      expect(SystemBars.light.statusBarColor, AppTheme.lightBackground);
      expect(SystemBars.dark.statusBarColor, AppTheme.darkBackground);

      // ...and the bottom-nav surface the navigation bar has to meet.
      for (final block in _themeBlocks(src)) {
        final expected = block.key == 'light' ? 'lightSurface' : 'darkSurface';
        expect(
          RegExp('bottomNavigationBarTheme: const '
                  r'BottomNavigationBarThemeData\(\s*'
                  'backgroundColor: $expected')
              .hasMatch(block.value),
          isTrue,
          reason: '${block.key} theme must seat its bottom bar on $expected, '
              'which is what SystemBars paints the navigation bar',
        );
      }
      expect(SystemBars.light.systemNavigationBarColor, AppTheme.lightSurface);
      expect(SystemBars.dark.systemNavigationBarColor, AppTheme.darkSurface);
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
      // Source-asserted for the same reason as above: building a ThemeData
      // pulls Poppins over the network.
      final src = File('lib/theme/app_theme.dart').readAsStringSync();
      for (final block in _themeBlocks(src)) {
        expect(
          RegExp(r'appBarTheme: const AppBarTheme\(\s*systemOverlayStyle: '
                  'SystemBars.${block.key},')
              .hasMatch(block.value),
          isTrue,
          reason: 'the ${block.key} AppBar must declare the same bars as the '
              'root owner, or the 26 screens that build one disagree with the '
              'rest of the app',
        );
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

/// The source of one theme getter from `app_theme.dart`, keyed 'light'/'dark'.
///
/// Read from source because constructing a [ThemeData] calls
/// `GoogleFonts.poppinsTextTheme()`, which fetches Poppins over the network and
/// throws under `flutter_test` — the font is not bundled in assets.
List<MapEntry<String, String>> _themeBlocks(String src) {
  final members = RegExp(r'^  static ', multiLine: true);
  return ['light', 'dark'].map((name) {
    final start = src.indexOf('get ${name}Theme');
    expect(start, isNot(-1), reason: 'AppTheme.${name}Theme not found');
    final next = members.firstMatch(src.substring(start));
    final end = next == null ? src.length : start + next.end;
    return MapEntry(name, src.substring(start, end));
  }).toList();
}
