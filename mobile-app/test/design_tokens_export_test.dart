import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/theme/tokens.dart';

/// THE APP EXPORTS ITS TOKENS. THE WEB PROPERTIES DO NOT RE-TYPE THEM.
///
/// ── Why this exists ─────────────────────────────────────────────────────
/// `help24_website/lib/tokens.ts` opens by calling itself "THE single source
/// of truth for the website", and then says every value in it "was read out of
/// the Flutter app". Both sentences were true and together they were the
/// problem: the transcription was manual, so the moment the app re-toned, the
/// website was confidently serving a palette the product no longer used —
/// `#6265F0` indigo, `#22D3EE` cyan, and a `STATUS_COLOR_CONFLICT` block that
/// only existed because the app had duplicate palettes it has since deleted.
///
/// Nothing was wrong with either file. What was wrong was that a human was the
/// integration.
///
/// ── Why this is a TEST and not a script ─────────────────────────────────
/// `tokens.dart` imports `package:flutter/material.dart`, so `Color` comes
/// from `dart:ui`. `dart run` cannot compile that — it dies in the FFI
/// transformer, which is not a fixable packaging detail, it is the engine
/// simply not being there. The Flutter test harness IS the environment where
/// these values exist, so the exporter lives where the values do.
///
/// That turns out to be the right place for a second reason: **the thing that
/// generates and the thing that detects drift are one file.** Edit
/// `tokens.dart`, forget to regenerate, and `flutter test` fails and tells you
/// the command to run. There is no pipeline to remember.
///
/// ── Why the output is committed JSON, not an import ─────────────────────
/// Two Next apps consume this. Neither gets a cross-package import, a build
/// step or a Dart dependency — the generated file is written INTO each app's
/// own `lib/` and committed. The web builds stay exactly as they are; this
/// test is what guarantees the two copies and the Dart source agree.
///
/// ── To regenerate ───────────────────────────────────────────────────────
///     flutter test test/design_tokens_export_test.dart --dart-define=update_tokens=true
void main() {
  /// Set by `--dart-define=update_tokens=true`. Writes instead of asserting.
  const updating = bool.fromEnvironment('update_tokens');

  /// Where the generated file lands. Relative to `mobile-app/`, which is the
  /// working directory `flutter test` runs in.
  ///
  /// Two copies on purpose. A shared file at the repo root would need either a
  /// cross-package import (fiddly and version-specific in Next's module
  /// resolution) or a copy step in two build pipelines. A small duplicated
  /// file that a test pins byte-for-byte is the cheaper guarantee.
  ///
  /// ── One of these is in a DIFFERENT REPOSITORY ─────────────────────────
  /// `help24_website/` is its own git repo with its own remote, and the parent
  /// repo gitignores it. `admin-dashboard/` is not. So a clean checkout of the
  /// mobile repo has one of these consumers and not the other, and a test that
  /// demanded both would fail for a reason that has nothing to do with the
  /// tokens.
  ///
  /// A target that is not checked out is therefore SKIPPED, and a target that
  /// IS checked out is verified strictly. That keeps the guarantee where it can
  /// be enforced without inventing a failure where it cannot.
  ///
  /// The corollary is worth stating plainly: because the website is a separate
  /// repo, a token change is not fully shipped until BOTH repos are committed.
  const targets = <String>[
    '../help24_website/lib/design-tokens.generated.json',
    '../admin-dashboard/lib/design-tokens.generated.json',
  ];

  /// True when the consumer this file belongs to is actually checked out.
  /// `lib/` existing is the signal — the generated file itself may be absent
  /// precisely because it has never been written.
  bool consumerPresent(String target) =>
      Directory(File(target).parent.path).existsSync();

  /// `#RRGGBB`, upper case.
  ///
  /// Every token colour is fully opaque by design — a token with alpha would
  /// mean the palette had started encoding *composition* rather than colour,
  /// which is how `withValues(alpha: 0.12)` tints ended up scattered across
  /// call sites in the first place. Asserted rather than assumed.
  String hex(Color c, String name) {
    final argb = c.toARGB32();
    expect(argb >> 24 & 0xFF, 0xFF,
        reason: '$name is not opaque; a token must be a colour, not a blend');
    return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  /// The colour roles, in a FIXED order. Not `Map.keys` off some reflective
  /// walk: the output is committed and diffed by humans, so the order has to
  /// be a decision rather than an accident of how the class was written.
  Map<String, String> colors(AppColors c, String theme) {
    final entries = <String, Color>{
      'page': c.page,
      'surface': c.surface,
      'surfaceSunken': c.surfaceSunken,
      'surfaceRaised': c.surfaceRaised,
      'navSurface': c.navSurface,
      'contentPrimary': c.contentPrimary,
      'contentSecondary': c.contentSecondary,
      'contentTertiary': c.contentTertiary,
      'borderHairline': c.borderHairline,
      'borderStrong': c.borderStrong,
      'actionFill': c.actionFill,
      'contentOnAction': c.contentOnAction,
      'accentFill': c.accentFill,
      'accentText': c.accentText,
      'accentSubtle': c.accentSubtle,
      'contentOnAccent': c.contentOnAccent,
      'positiveText': c.positiveText,
      'positiveFill': c.positiveFill,
      'positiveSubtle': c.positiveSubtle,
      'cautionText': c.cautionText,
      'cautionFill': c.cautionFill,
      'cautionSubtle': c.cautionSubtle,
      'criticalText': c.criticalText,
      'criticalFill': c.criticalFill,
      'criticalSubtle': c.criticalSubtle,
      'infoText': c.infoText,
      'infoFill': c.infoFill,
      'infoSubtle': c.infoSubtle,
      'neutralSubtle': c.neutralSubtle,
    };
    return {
      for (final e in entries.entries) e.key: hex(e.value, '$theme.${e.key}'),
    };
  }

  /// One type role. `height` in Flutter is a MULTIPLIER of the font size; CSS
  /// and every design tool want the resolved pixel value, so both are emitted
  /// and neither consumer has to know the conversion.
  Map<String, Object> type(TextStyle s, {bool tabular = false}) {
    final size = s.fontSize!;
    return <String, Object>{
      'fontSize': size,
      'lineHeight': (size * s.height!).round(),
      'fontWeight': s.fontWeight!.value,
      if (s.letterSpacing != null) 'letterSpacing': s.letterSpacing!,
      if (tabular) 'tabularFigures': true,
    };
  }

  String buildExport() {
    final payload = <String, Object>{
      // A machine-readable note, because the first thing anyone does with an
      // unfamiliar generated file is try to edit it.
      'GENERATED': 'Do not edit. Source: mobile-app/lib/theme/tokens.dart. '
          'Regenerate: cd mobile-app && flutter test '
          'test/design_tokens_export_test.dart --dart-define=update_tokens=true',
      'color': {
        'light': colors(AppColors.light, 'light'),
        'dark': colors(AppColors.dark, 'dark'),
      },
      'radius': <String, double>{
        'sm': AppRadius.sm,
        'md': AppRadius.md,
        'lg': AppRadius.lg,
        'sheet': AppRadius.sheet,
        'pill': AppRadius.pill,
      },
      'space': <String, double>{
        'xs': AppSpace.xs,
        'sm': AppSpace.sm,
        'md': AppSpace.md,
        'lg': AppSpace.lg,
        'xl': AppSpace.xl,
        'xxl': AppSpace.xxl,
        'xxxl': AppSpace.xxxl,
        'gutter': AppSpace.gutter,
        'section': AppSpace.section,
      },
      'type': <String, Object>{
        'family': AppTypeScale.family,
        'displayS': type(AppTypeScale.displayS),
        'headingL': type(AppTypeScale.headingL),
        'headingM': type(AppTypeScale.headingM),
        'headingS': type(AppTypeScale.headingS),
        'bodyL': type(AppTypeScale.bodyL),
        'bodyM': type(AppTypeScale.bodyM),
        'bodyS': type(AppTypeScale.bodyS),
        'label': type(AppTypeScale.label),
        'meta': type(AppTypeScale.meta),
        'mono': type(AppTypeScale.mono, tabular: true),
      },
      // Durations only. The curves are Flutter `Curve` objects with no honest
      // CSS equivalent, and guessing a cubic-bezier for `Curves.easeOut` would
      // be inventing a value and calling it generated.
      'motion': <String, int>{
        'state': AppMotion.state.inMilliseconds,
        'transition': AppMotion.transition.inMilliseconds,
        'sheet': AppMotion.sheet.inMilliseconds,
      },
    };
    // Trailing newline so the file is POSIX-clean and diffs do not show a
    // "\ No newline at end of file" marker on every regeneration.
    return '${const JsonEncoder.withIndent('  ').convert(payload)}\n';
  }

  test('the generated token file matches lib/theme/tokens.dart', () {
    final expected = buildExport();

    final present = targets.where(consumerPresent).toList();
    expect(present, isNotEmpty,
        reason: 'no token consumer is checked out beside mobile-app/ — '
            'expected at least one of:\n${targets.join('\n')}');

    if (updating) {
      for (final path in present) {
        File(path)
          ..createSync(recursive: true)
          ..writeAsStringSync(expected);
      }
      // Not a silent pass: regenerating is a deliberate act and should say so,
      // including when a consumer was skipped because it is not checked out.
      final skipped = targets.length - present.length;
      // ignore: avoid_print
      print('[TOKENS] wrote ${present.length} file(s) from tokens.dart'
          '${skipped > 0 ? ' ($skipped consumer not checked out)' : ''}');
      return;
    }

    for (final path in present) {
      final file = File(path);
      expect(file.existsSync(), isTrue,
          reason: '$path is missing. Generate it with:\n'
              '  flutter test test/design_tokens_export_test.dart '
              '--dart-define=update_tokens=true');
      expect(
        file.readAsStringSync().replaceAll('\r\n', '\n'),
        expected,
        reason: '$path has drifted from tokens.dart.\n\n'
            'This is the whole point of the file: the website and the admin '
            'dashboard used to re-type these values by hand, which is how the '
            'web came to be serving a palette the app had already retired.\n\n'
            'Regenerate with:\n'
            '  cd mobile-app && flutter test '
            'test/design_tokens_export_test.dart '
            '--dart-define=update_tokens=true',
      );
    }
  });

  test('every checked-out consumer holds a byte-identical copy', () {
    if (updating) return;
    final contents = targets
        .where(consumerPresent)
        .map((p) => File(p))
        .where((f) => f.existsSync())
        .map((f) => f.readAsStringSync().replaceAll('\r\n', '\n'))
        .toSet();
    expect(contents.length, lessThanOrEqualTo(1),
        reason: 'the two generated copies disagree, which means one was '
            'edited by hand — they are outputs, not sources');
  });

  test('a consumer that is not checked out is skipped, not failed', () {
    // The website lives in its own repository, so a clean checkout of this one
    // has `admin-dashboard/` and no `help24_website/`. Pinning that behaviour
    // here rather than by deleting a directory to watch what happens.
    expect(consumerPresent('../admin-dashboard/lib/design-tokens.generated.json'),
        isTrue,
        reason: 'admin-dashboard is in this repository and must always be seen');
    expect(
        consumerPresent('../no-such-consumer/lib/design-tokens.generated.json'),
        isFalse);
  });

  test('every exported colour is a real measurement, not a placeholder', () {
    // A cheap trap for the failure mode this whole file exists to prevent:
    // a retired value reappearing. These are the hexes the token layer
    // replaced; none of them may ever be exported again.
    final json = buildExport();
    for (final ghost in const [
      '#6265F0', // the old indigo accent
      '#22D3EE', // the old cyan secondary
      '#818CF8', // primary-bright, invented to work around indigo on dark
      '#E53935', // urgency red
      '#FF9800', // urgency amber
      '#4CAF50', // urgency green / offer badge
      '#2196F3', // request badge
      '#9C27B0', // job badge
    ]) {
      expect(json.contains(ghost), isFalse,
          reason: '$ghost is a value the token layer replaced');
    }
  });
}
