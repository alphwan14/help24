import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// COLOUR AND SHAPE COME FROM THE TOKEN LAYER, AND CANNOT QUIETLY STOP.
///
/// WHAT THIS EXISTS TO PREVENT
/// ---------------------------
/// The audit that produced `lib/theme/tokens.dart` found **39 distinct
/// hard-coded hex values across 13 files**, plus `Colors.red` ×13 and
/// `Colors.grey` ×5 — Material constants that do not change between light and
/// dark at all. Red, amber and green were each defined TWICE, and by the time
/// every copy was found it was worse than that: the urgency palette existed in
/// `PostModel`, in `JobModel` AND in `marketplace_card_components`, and the
/// type-badge palette in `PostModel` AND in the composer. Three and two
/// hand-maintained copies of one idea, none agreeing with `AppTheme`.
///
/// That is how a single feed card came to show a `Soon` tag in `#FF9800`
/// beside a `Payment Protected` tag in `#F59E0B`: two ambers, two pixels
/// apart. Nothing was broken, nothing failed to compile, and no reviewer could
/// see it without opening four files.
///
/// None of it came back on its own. It came back one reasonable-looking line
/// at a time.
void main() {
  /// Every .dart file under lib/, as (repo-relative path, source).
  List<MapEntry<String, String>> libSources() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => MapEntry(
            f.path.replaceAll(r'\', '/'),
            f.readAsStringSync(),
          ))
      .toList();

  /// Files allowed to name a colour directly, each for a stated reason.
  ///
  /// This list may SHRINK. Adding to it is a design decision and should be
  /// argued for in review, not slipped in to make a test pass.
  const allowed = <String, String>{
    // The token layer itself. This is where colour is allowed to be a number.
    'lib/theme/tokens.dart': 'defines the palette',
    'lib/theme/app_theme.dart': 'builds ThemeData from the palette',
    // The status/navigation bar styles, and the window background behind the
    // splash. These must match `values/styles.xml` exactly — they are shared
    // with a file Flutter does not compile.
    'lib/theme/system_bars.dart': 'must match android styles.xml',
    'lib/widgets/launch_splash.dart': 'brand ink, matches the window background',
    // Google mandates the exact colours of the Sign-in-with-Google button in
    // its branding guidelines. Theming it would breach them.
    'lib/screens/auth_screen.dart': 'Google Sign-In button brand colours',
    // A DEV-only debug overlay, never built in release. It is deliberately
    // unlike the product so it can never be mistaken for it.
    'lib/screens/payment_screen.dart': 'dev-only debug overlay',
  };

  group('colour comes from the token layer', () {
    test('no file outside the allowlist writes a raw hex colour', () {
      final offenders = <String>[];
      for (final file in libSources()) {
        if (allowed.containsKey(file.key)) continue;
        final hits = RegExp(r'Color\(0x[0-9A-Fa-f]{6,8}\)')
            .allMatches(file.value)
            .map((m) => m.group(0)!)
            .toSet();
        if (hits.isNotEmpty) offenders.add('${file.key}: ${hits.join(', ')}');
      }
      expect(
        offenders,
        isEmpty,
        reason: 'A raw hex cannot be brightness-aware and cannot be found by '
            'anyone looking for "the red". Use AppColors.of(context).\n'
            '${offenders.join('\n')}',
      );
    });

    test('no file outside the allowlist uses a theme-blind Material colour',
        () {
      // Colors.white / .black / .transparent are excluded: they are absolutes,
      // not theme choices, and a label ON a known fill legitimately names one.
      final blind = RegExp(
          r'Colors\.(red|green|blue|orange|amber|grey|gray|purple|teal|'
          r'yellow|pink|indigo|cyan|lime|brown)[0-9]*');
      final offenders = <String>[];
      for (final file in libSources()) {
        if (allowed.containsKey(file.key)) continue;
        final hits =
            blind.allMatches(file.value).map((m) => m.group(0)!).toSet();
        if (hits.isNotEmpty) offenders.add('${file.key}: ${hits.join(', ')}');
      }
      expect(
        offenders,
        isEmpty,
        reason: 'Colors.red is the same red in both themes, which is how the '
            'dispute screen came to render #F44336 — a THIRD red — beside '
            'AppTheme.errorRed and PostModel\'s #E53935.\n'
            '${offenders.join('\n')}',
      );
    });

    test('a semantic role is defined exactly once', () {
      // The specific failure this pins: red, amber and green each had two
      // definitions, and both rendered on the same card.
      final theme = File('lib/theme/app_theme.dart').readAsStringSync();
      for (final ghost in const [
        '0xFFE53935', // urgency red   — was PostModel + JobModel + the chip
        '0xFFFF9800', // urgency amber
        '0xFF4CAF50', // urgency green / offer badge
        '0xFF2196F3', // request badge — Material 2014
        '0xFF9C27B0', // job badge
        '0xFF6265F0', // the old indigo accent
        '0xFF22D3EE', // the old cyan secondary
      ]) {
        expect(theme.contains(ghost), isFalse,
            reason: '$ghost is a value the token layer replaced; if it is '
                'back, one of the old palettes came with it');
      }
    });
  });

  group('shape', () {
    // ── THIS USED TO BE A RATCHET ────────────────────────────────────────
    //
    // The audit counted **19 distinct corner radii across 291 call sites**
    // (1, 2, 3, 4, 6, 8, 9, 10, 11, 12, 14, 15, 16, 18, 20, 22, 24, 26, 50).
    // Converging them was a sprint of its own, so this test originally only
    // held the line — off-scale radii could fall, never rise, from a baseline
    // of 172 — and said that when the count dropped it should become a gate.
    //
    // It has. There is now no number here at all: every radius in the app is
    // named, and `lib/theme/tokens.dart` is the only file allowed to say what
    // the names are worth.
    //
    // ── What the convergence actually found ──────────────────────────────
    // Most of the 19 values were never really different radii. They were one
    // intention written many ways:
    //
    //   * 1, 2, 3, 4, 6, 50 and most of the 20s were PILLS — a 4 px drag
    //     handle, a 6 px carousel dot, a 100 px avatar, a 20 px chip. Each
    //     was a hand-computed "half my own height", and each silently became
    //     wrong the moment the element was resized.
    //   * 24 was the SHEET radius, used consistently by 16 of the 22 places
    //     that round the top of a modal — a rung the four-value scale was
    //     missing rather than a drift.
    //   * The rest rounded to the nearest of sm / md / lg by role:
    //     controls to md, content surfaces to lg, tags to sm.
    const scaleOwner = 'lib/theme/tokens.dart';

    test('no file but the token layer writes a numeric corner radius', () {
      final offenders = <String>[];
      for (final file in libSources()) {
        if (file.key == scaleOwner) continue;
        final hits = RegExp(r'Radius\.circular\(\s*\d')
            .allMatches(file.value)
            .length;
        if (hits > 0) offenders.add('${file.key}: $hits');
      }
      expect(
        offenders,
        isEmpty,
        reason: 'A radius written as a number cannot be found by anyone '
            'looking for "the card radius", and cannot move when the scale '
            'does. Use AppRadius.smAll / mdAll / lgAll / pillAll / sheetTop, '
            'or AppRadius.sm / md / lg / sheet / pill inside a Radius.\n'
            '${offenders.join('\n')}',
      );
    });

    test('the scale is exactly five rungs, and each one is named', () {
      // Five, not four. The fifth (`sheet`) is argued for in tokens.dart: a
      // radius reads relative to the surface carrying it, so a full-width
      // sheet and a 340 px card cannot share one value. Adding a sixth is a
      // design decision — make it here, deliberately, or not at all.
      final tokens = File(scaleOwner).readAsStringSync();
      const rungs = {
        'sm': 8,
        'md': 12,
        'lg': 16,
        'sheet': 24,
        'pill': 999,
      };
      for (final entry in rungs.entries) {
        expect(
          tokens,
          contains('static const double ${entry.key} = ${entry.value};'),
          reason: 'AppRadius.${entry.key} must stay ${entry.value}',
        );
      }
      final declared = RegExp(r'static const double (\w+) = \d+;')
          .allMatches(tokens)
          .map((m) => m.group(1)!)
          .where(rungs.containsKey)
          .toSet();
      expect(declared.length, rungs.length);
    });
  });
}
