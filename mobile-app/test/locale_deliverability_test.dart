import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/providers/locale_provider.dart';

/// THE APP DOES NOT OFFER A LANGUAGE IT CANNOT BE USED IN.
///
/// WHAT WAS WRONG
/// --------------
/// `assets/l10n/sw.json` exists and has the same 39 keys as `en.json`, so on
/// paper Help24 was bilingual. In practice every `AppLocalizations` call site
/// in the app is inside `profile_screen.dart` — the settings list. Switching to
/// Kiswahili would have translated the settings labels and left the user in
/// English for the feed, the composer, applying, payments, escrow and disputes.
///
/// The Language picker already refused Kiswahili at the point of choice
/// ("Coming soon", with a padlock). But `users.language` is a STORED value, and
/// both the load path and the setter accepted `'sw'` from it — so an account
/// carrying that value from an earlier build got exactly the half-translated
/// app the picker existed to prevent. The picker guarded the door; nothing
/// guarded the window.
///
/// These tests pin the window shut, and pin the coverage claim that justifies
/// it — so that when somebody does the translation work, the test tells them
/// what "done" means rather than just failing.
void main() {
  group('a stored language the app cannot honour is refused', () {
    test('English is deliverable', () {
      expect(LocaleProvider.canDeliver('en'), isTrue);
    });

    test('Kiswahili is NOT deliverable yet', () {
      expect(LocaleProvider.canDeliver('sw'), isFalse,
          reason: 'a bundle that covers the settings screen is not a language '
              'the product supports');
    });

    test('null and unknown codes are refused', () {
      expect(LocaleProvider.canDeliver(null), isFalse);
      expect(LocaleProvider.canDeliver('fr'), isFalse);
      expect(LocaleProvider.canDeliver(''), isFalse);
    });

    test('setLocale ignores a language the app cannot deliver', () {
      final provider = LocaleProvider();
      expect(provider.languageCode, 'en');
      provider.setLocale(const Locale('sw'));
      expect(provider.languageCode, 'en',
          reason: 'this is the path a stored value reaches the app by');
    });

    test('setLocale does not notify when it refuses', () {
      final provider = LocaleProvider();
      var notified = 0;
      provider.addListener(() => notified++);
      provider.setLocale(const Locale('sw'));
      expect(notified, 0);
    });
  });

  group('the setting is hidden while there is nothing to choose', () {
    test('offersAChoice is false with one deliverable language', () {
      expect(LocaleProvider.offersAChoice, isFalse);
    });

    test('Profile gates the Language row on it', () {
      final profile =
          File('lib/screens/profile_screen.dart').readAsStringSync();
      expect(
        profile,
        contains('if (LocaleProvider.offersAChoice)'),
        reason: 'a setting with one option is not a setting; the row must come '
            'back in the same change that makes a second language deliverable',
      );
    });
  });

  group('the coverage claim is true', () {
    test('every AppLocalizations call site is still in one file', () {
      // The whole argument for the gate is that localisation reaches one
      // screen. If that stops being true, this test should be the thing that
      // notices — the gate may be ready to open.
      final callers = <String, int>{};
      for (final file in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        // Comments are stripped first: the reasoning for this gate NAMES the
        // accessor, and a doc comment is not a call site.
        final code = file
            .readAsStringSync()
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        final hits = RegExp(r'AppLocalizations\.of\(').allMatches(code).length;
        if (hits == 0) continue;
        final path = file.path.replaceAll(r'\', '/');
        // The library that DEFINES the accessor is not a call site.
        if (path.endsWith('lib/l10n/app_localizations.dart')) continue;
        callers[path] = hits;
      }
      expect(
        callers.keys,
        ['lib/screens/profile_screen.dart'],
        reason: 'localisation now reaches more than the settings list — '
            'recount the coverage and reconsider LocaleProvider._deliverable.\n'
            'Call sites: $callers',
      );
    });

    test('both bundles exist and agree on their keys', () {
      // Kept working on purpose: shipping Kiswahili should be translation work
      // plus one line, not a rebuild of the plumbing.
      Map<String, dynamic> load(String code) => jsonDecode(
            File('assets/l10n/$code.json').readAsStringSync(),
          ) as Map<String, dynamic>;
      final en = load('en');
      final sw = load('sw');
      expect(en.keys.toSet(), sw.keys.toSet(),
          reason: 'the bundles must stay in step so the gap is coverage, '
              'not correctness');
    });
  });
}
