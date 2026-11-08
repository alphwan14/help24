import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/profile_setup.dart';

void main() {
  group('Complete your profile', () {
    test('a new member has four steps and none done', () {
      final s = ProfileSetup.evaluate(
        profileComplete: false,
        isProvider: false,
        idVerified: false,
        hasPayout: false,
        payoutAvailable: true,
      )!;
      expect(s.total, 4);
      expect(s.completed, 0);
      expect(s.next, SetupStep.completeProfile);
      expect(s.isComplete, isFalse);
    });

    test('the next step is the first one not done', () {
      final s = ProfileSetup.evaluate(
        profileComplete: true,
        isProvider: true,
        idVerified: false,
        hasPayout: true,
        payoutAvailable: true,
      )!;
      expect(s.completed, 3);
      expect(s.next, SetupStep.verifyIdentity);
    });

    test('all steps done means complete, and the row hides', () {
      final s = ProfileSetup.evaluate(
        profileComplete: true,
        isProvider: true,
        idVerified: true,
        hasPayout: true,
        payoutAvailable: true,
      )!;
      expect(s.isComplete, isTrue);
      expect(s.next, isNull);
      expect(s.fraction, 1);
    });

    test('payout numbers switched off on the server leave the step out', () {
      final s = ProfileSetup.evaluate(
        profileComplete: true,
        isProvider: true,
        idVerified: false,
        hasPayout: null,
        payoutAvailable: false,
      )!;
      expect(s.steps, [
        SetupStep.completeProfile,
        SetupStep.offerServices,
        SetupStep.verifyIdentity,
      ]);
      expect(s.total, 3);
      expect(s.completed, 2);
    });

    test('a failed read hides the row instead of guessing a count', () {
      expect(
        ProfileSetup.evaluate(
          profileComplete: true,
          isProvider: true,
          idVerified: null,
          hasPayout: true,
          payoutAvailable: true,
        ),
        isNull,
      );
      expect(
        ProfileSetup.evaluate(
          profileComplete: true,
          isProvider: true,
          idVerified: true,
          hasPayout: null,
          payoutAvailable: true,
        ),
        isNull,
      );
    });
  });
}
