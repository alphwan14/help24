import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/screens/terms_acceptance_screen.dart';
import 'package:help24/services/terms_acceptance.dart';
import 'package:help24/theme/app_theme.dart';
import 'package:help24/utils/payment_utils.dart';
import 'package:help24/utils/terms_copy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The terms a new install accepts must say what the code does.
///
/// Every money sentence in TermsCopy is checked against the constant that
/// implements it, so a change to the fee or the review window that forgets
/// the terms fails here instead of putting a false promise in front of
/// every new member.
String all() => [
      TermsCopy.title,
      TermsCopy.lead,
      for (final s in TermsCopy.sections) '${s.heading} ${s.body}',
      TermsCopy.agreementNote,
    ].join('\n');

String section(String heading) => TermsCopy.sections.firstWhere((s) => s.heading == heading).body;

void main() {
  group('the summary matches the code', () {
    test('the fee: 5%, minimum, maximum, and shown before paying', () {
      final pay = section('Paying through Help24');
      expect(pay, contains('$feeRatePercent%'));
      expect(pay, contains('at least KES $feeMinKes'));
      expect(pay, contains('never more than KES 1,000'));
      expect(feeMaxKes, 1000);
      expect(pay, contains('shown before you confirm'));
      expect(pay, contains('full agreed price'));
    });

    test('the review window is 48 hours, then approval', () {
      final review = section('Approving the work');
      expect(review, contains('48 hours'));
      expect(review, contains('approve it or open a dispute'));
    });

    test('the refund promise is the honest one: what Help24 holds, fee included', () {
      final refund = section('If something goes wrong');
      expect(refund, contains('money stays held'));
      expect(refund, contains('everything Help24 holds for the job, including the fee'));
      expect(refund, contains('split'));
      // Never a promise beyond what the system holds.
      expect(refund.toLowerCase(), isNot(contains('guarantee')));
      expect(refund.toLowerCase(), isNot(contains('100%')));
    });

    test('Materials Advance: sent only on Send, the rest comes back', () {
      final adv = section('Materials Advance');
      expect(adv, contains('40%'));
      expect(adv, contains('Nothing is sent until you tap Send'));
      expect(adv, contains('cannot be held back'));
      expect(adv, contains('fee included'));
    });

    test('only in-app payments are protected, and only they earn reviews', () {
      final s = section('Only payments in the app are protected');
      expect(s, contains('cannot protect cash'));
      expect(s, contains('review'));
    });

    test('the age and data lines match the website terms and privacy policy', () {
      expect(section('What Help24 is'), contains('18 or older'));
      expect(section('Your data'), contains('We do not sell your personal data'));
    });

    test('plain copy: no em dashes, nothing that sounds like a template', () {
      expect(all().contains('—'), isFalse);
      for (final word in ['seamless', 'leverage', 'empower', 'robust', 'delve']) {
        expect(all().toLowerCase(), isNot(contains(word)));
      }
    });
  });

  group('acceptance is versioned and remembered', () {
    test('a fresh install has not accepted; accepting is remembered', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      TermsAcceptance.load(prefs);
      expect(TermsAcceptance.isAccepted, isFalse);
      await TermsAcceptance.accept(now: DateTime.utc(2026, 11, 10, 9));
      expect(prefs.getString('terms_accepted_version'), TermsAcceptance.currentVersion);
      TermsAcceptance.load(prefs);
      expect(TermsAcceptance.isAccepted, isTrue);
      expect(TermsAcceptance.acceptedAt, DateTime.utc(2026, 11, 10, 9));
      await expectLater(TermsAcceptance.ready, completes);
    });

    test('an older accepted version asks again', () async {
      SharedPreferences.setMockInitialValues({'terms_accepted_version': '2026-01-01'});
      TermsAcceptance.load(await SharedPreferences.getInstance());
      expect(TermsAcceptance.isAccepted, isFalse);
    });
  });

  testWidgets('the screen shows every section and records the agreement', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TermsAcceptance.load(await SharedPreferences.getInstance());
    var accepted = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: TermsAcceptanceScreen(onAccepted: () => accepted = true),
    ));
    expect(find.text(TermsCopy.title), findsOneWidget);
    // The list builds lazily: scroll to the refund section the way a reader would.
    await tester.scrollUntilVisible(find.text('If something goes wrong'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('If something goes wrong'), findsOneWidget);
    await tester.scrollUntilVisible(find.text(TermsCopy.readPrivacy), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text(TermsCopy.readTerms), findsOneWidget);
    // The agreement is always on screen, never at the end of a scroll.
    expect(find.text(TermsCopy.accept), findsOneWidget);
    expect(find.text(TermsCopy.close), findsOneWidget);

    await tester.tap(find.text(TermsCopy.accept));
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
    expect(TermsAcceptance.isAccepted, isTrue);
  });
}
