import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/email_verification_cooldown.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The pause between confirmation emails.
///
/// WHAT THIS LOCKS DOWN, AND WHY IT IS WORTH A TEST FILE
/// ----------------------------------------------------
/// The reported symptom was "Too many attempts" while trying to confirm a new
/// account. The provider's rate limit produced that sentence, but three
/// properties of OUR code are what walked the user into it:
///
///   1. `signUp` sends one email and nothing said so, so the user's first act
///      was to ask for another.
///   2. The pause was armed only after a SUCCESSFUL send. A rejection — the
///      rate limit included — left the button live, and every further tap
///      extended the block.
///   3. The pause lived in widget state, so an app restart cleared it. A
///      restart is exactly what happens between the sends that consume the
///      quota.
///
/// (2) and (3) are what these tests hold down. (1) is the confirmation step in
/// auth_screen.dart.
void main() {
  const uid = 'firebase-uid-abc123';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('a send arms the next pause', () {
    test('nothing is pending before the first send', () async {
      expect(await EmailVerificationCooldown.remaining(uid), Duration.zero);
    });

    test('the first send buys under a minute, not nothing', () async {
      await EmailVerificationCooldown.recordSend(uid);
      final left = await EmailVerificationCooldown.remaining(uid);
      expect(left, greaterThan(Duration.zero));
      // Short enough that a genuinely lost first email is not a punishment.
      expect(left, lessThanOrEqualTo(const Duration(seconds: 45)));
    });

    test('each further send costs more than the last', () async {
      final waits = <Duration>[];
      for (var i = 0; i < 4; i++) {
        await EmailVerificationCooldown.recordSend(uid);
        waits.add(await EmailVerificationCooldown.remaining(uid));
      }
      for (var i = 1; i < waits.length; i++) {
        expect(waits[i], greaterThan(waits[i - 1]),
            reason: 'send ${i + 1} must wait longer than send $i');
      }
    });
  });

  group("a refusal pauses too — the bug this file exists for", () {
    test('a provider block arms a pause even though nothing was sent',
        () async {
      // The old code did `if (ok) startCooldown()`, so this case armed
      // NOTHING: the button returned to "Try again" the instant the provider
      // said stop.
      await EmailVerificationCooldown.recordProviderBlock(uid);
      final left = await EmailVerificationCooldown.remaining(uid);
      expect(left, greaterThan(const Duration(minutes: 1)));
    });

    test('a refusal does not also advance our own backoff', () async {
      // The send never happened. Counting it would charge the user twice for
      // one refusal — a longer wait now AND a longer wait next time.
      await EmailVerificationCooldown.recordProviderBlock(uid);
      await EmailVerificationCooldown.clear(uid);
      await EmailVerificationCooldown.recordSend(uid);
      expect(await EmailVerificationCooldown.remaining(uid),
          lessThanOrEqualTo(const Duration(seconds: 45)));
    });

    test('a refusal never shortens a pause that is already longer', () async {
      for (var i = 0; i < 4; i++) {
        await EmailVerificationCooldown.recordSend(uid);
      }
      final before = await EmailVerificationCooldown.remaining(uid);
      await EmailVerificationCooldown.recordProviderBlock(uid);
      final after = await EmailVerificationCooldown.remaining(uid);
      expect(after, greaterThanOrEqualTo(before - const Duration(seconds: 1)));
    });
  });

  group('the pause outlives the screen that set it', () {
    test('it is on disk, so a fresh read still sees it', () async {
      await EmailVerificationCooldown.recordSend(uid);
      // A new app launch reads the same store; nothing in memory carries over.
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(await EmailVerificationCooldown.remaining(uid),
          greaterThan(Duration.zero));
    });

    test('one account never inherits another account\'s pause', () async {
      await EmailVerificationCooldown.recordSend(uid);
      expect(await EmailVerificationCooldown.remaining('some-other-uid'),
          Duration.zero);
    });

    test('confirming the address clears it', () async {
      await EmailVerificationCooldown.recordSend(uid);
      await EmailVerificationCooldown.clear(uid);
      expect(await EmailVerificationCooldown.remaining(uid), Duration.zero);
    });

    test('a signed-out caller is never blocked', () async {
      // uid is empty before a session exists; a pause that applied to "nobody"
      // would apply to everybody.
      expect(await EmailVerificationCooldown.remaining(''), Duration.zero);
    });
  });

  group('the countdown reads like a countdown', () {
    test('under a minute counts seconds', () {
      expect(EmailVerificationCooldown.format(const Duration(seconds: 45)),
          '45s');
      expect(EmailVerificationCooldown.format(const Duration(seconds: 9)), '9s');
    });

    test('over a minute reads as a clock, not as 150 seconds', () {
      expect(EmailVerificationCooldown.format(const Duration(seconds: 150)),
          '2:30');
      expect(EmailVerificationCooldown.format(const Duration(minutes: 5)),
          '5:00');
    });

    test('nothing left renders as nothing at all', () {
      expect(EmailVerificationCooldown.format(Duration.zero), '');
      expect(EmailVerificationCooldown.format(const Duration(seconds: -5)), '');
    });
  });
}
