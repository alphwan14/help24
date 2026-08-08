import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/payout_authority.dart';

/// §M4 — "there is exactly ONE authoritative UI for configuring where provider
/// payouts are sent". These tests pin both halves of that: the decision
/// function that decides what the legacy screen may claim, and a copy guard
/// that fails if the removed language ever comes back.
void main() {
  group('resolvePayoutAuthority', () {
    test('feature live → destinations own payouts', () {
      expect(
        resolvePayoutAuthority(reachable: true, featureUnavailable: false),
        PayoutAuthority.destinations,
      );
    });

    test('503 → the profile number really is the payout destination', () {
      // Matches the backend flag-off branch in mpesa.service.ts, which settles
      // B2C to users.phone_number. Denying it here would be a lie that makes a
      // provider think they are unpayable when they are not.
      expect(
        resolvePayoutAuthority(reachable: true, featureUnavailable: true),
        PayoutAuthority.profileNumber,
      );
    });

    test('unreachable → unknown, never a guess', () {
      expect(
        resolvePayoutAuthority(reachable: false, featureUnavailable: false),
        PayoutAuthority.unknown,
      );
    });

    test('unreachable outranks everything', () {
      expect(
        resolvePayoutAuthority(reachable: false, featureUnavailable: true),
        PayoutAuthority.unknown,
      );
    });
  });

  group('payoutNoteFor', () {
    test('unknown says nothing at all', () {
      expect(payoutNoteFor(PayoutAuthority.unknown), isNull);
    });

    test('destinations disclaims payout authority and names the real surface', () {
      final note = payoutNoteFor(PayoutAuthority.destinations)!;
      expect(note, contains('NOT'));
      expect(note, contains('Payout Destinations'));
    });

    test('profileNumber admits the number governs payouts today', () {
      final note = payoutNoteFor(PayoutAuthority.profileNumber)!;
      expect(note.toLowerCase(), contains('payouts currently go to this number'));
    });

    test('no state claims both roles at once', () {
      // The whole M4 defect in one assertion: a single note must never say the
      // number both does and does not receive payouts.
      for (final a in PayoutAuthority.values) {
        final note = payoutNoteFor(a);
        if (note == null) continue;
        final saysPays = note.contains('NOT sent here');
        final saysReceives = note.contains('currently go to this number');
        expect(saysPays && saysReceives, isFalse, reason: 'ambiguous note for $a');
      }
    });
  });

  group('copy guard — the legacy surface must not re-acquire payout language', () {
    /// Files that describe the PROFILE number (users.phone_number). The payout
    /// screens are excluded because saying "earnings are sent here" is their
    /// actual job.
    const profileNumberSurfaces = <String>[
      'lib/screens/profile_screen.dart',
      'lib/screens/professional_profile_screen.dart',
      'lib/widgets/provider_gate.dart',
      'lib/models/profile_completion.dart',
      'lib/screens/provider/provider_onboarding_screen.dart',
    ];

    test('the phrase "payments and payouts" is gone from every surface', () {
      for (final path in profileNumberSurfaces) {
        final source = File(path).readAsStringSync();
        expect(
          source.toLowerCase(),
          isNot(contains('payments and payouts')),
          reason: '$path re-introduced the M4 copy',
        );
      }
    });

    test('no surface still calls itself "Payment Settings"', () {
      for (final path in profileNumberSurfaces) {
        final source = File(path).readAsStringSync();
        expect(
          source,
          isNot(contains('Payment Settings')),
          reason: '$path still uses the ambiguous legacy name',
        );
      }
    });

    test('the provider gate does not claim the contact number pays you', () {
      final source = File('lib/widgets/provider_gate.dart').readAsStringSync();
      expect(source, isNot(contains('This is how you get paid')));
    });

    test('only PayoutDestinationsScreen is reachable as a payout editor', () {
      // A second editor would recreate M4 no matter how the copy reads. The
      // constructor is the thing to count: exactly one screen may exist that
      // adds/verifies/defaults a payout destination.
      final editors = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => f.readAsStringSync().contains('PayoutService.addDestination'))
          .map((f) => f.path.replaceAll(r'\', '/'))
          .toList();
      expect(
        editors,
        ['lib/screens/provider/payout_destinations_screen.dart'],
        reason: 'a second payout editor would re-create M4',
      );
    });
  });
}
