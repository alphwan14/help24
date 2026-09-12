import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/utils/auth_error_mapper.dart';

/// Vocabulary a Help24 user must never encounter. This list is the product
/// requirement expressed as a test: if any of these words can reach the
/// screen, the white-labelling has failed.
const _forbidden = <String>[
  'firebase',
  'firebaseapp',
  'supabase',
  'render',
  'onrender',
  'google provider',
  'identity toolkit',
  'identitytoolkit',
  'play integrity',
  'recaptcha',
  'safetynet',
  'app check',
  'oauth',
  'saml',
  'sessionstorage',
  'api key',
  'jwt',
  'sdk',
  'exception',
  'null',
];

void _expectClean(AuthFailure failure, {required String because}) {
  final text = '${failure.title} ${failure.message}'.toLowerCase();
  for (final word in _forbidden) {
    expect(text.contains(word), isFalse,
        reason: 'leaked "$word" ($because): ${failure.title} — ${failure.message}');
  }
  expect(failure.title.trim(), isNotEmpty);
  expect(failure.message.trim(), isNotEmpty);
}

void main() {
  _verificationCopy();
  group('the messages that drove this work', () {
    test('Play Integrity / reCAPTCHA prose never reaches the user', () {
      // Verbatim provider copy that real Help24 users were shown.
      final failure = AuthErrorMapper.toFailure(
        FirebaseAuthException(
          code: 'missing-client-identifier',
          message: 'This request is missing a valid app identifier, meaning that '
              'Play Integrity checks and reCAPTCHA checks were unsuccessful.',
        ),
        flow: AuthFlow.sendCode,
      );
      _expectClean(failure, because: 'integrity failure');
      expect(failure.message, contains('verify your device'));
      expect(failure.recovery, AuthRecovery.updateApp);
    });

    test('browser sessionStorage prose never reaches the user', () {
      final failure = AuthErrorMapper.toFailure(
        FirebaseAuthException(
          code: 'internal-error',
          message: 'Unable to process request due to missing initial state. '
              'This may happen if browser sessionStorage is inaccessible or '
              'accidentally cleared.',
        ),
        flow: AuthFlow.signIn,
      );
      _expectClean(failure, because: 'browser hand-off failure');
      expect(failure.message, contains('return to Help24'));
    });
  });

  group('every known provider code maps to clean copy', () {
    const codes = [
      'user-not-found', 'email-already-in-use', 'wrong-password',
      'invalid-credential', 'invalid-email', 'weak-password', 'user-disabled',
      'requires-recent-login', 'account-exists-with-different-credential',
      'credential-already-in-use', 'invalid-phone-number',
      'invalid-verification-code', 'session-expired', 'code-expired',
      'invalid-verification-id', 'missing-verification-id', 'quota-exceeded',
      'missing-client-identifier', 'app-not-authorized',
      'invalid-app-credential', 'captcha-check-failed',
      'network-request-failed', 'too-many-requests', 'operation-not-allowed',
      'not-configured', 'unsupported-first-factor', 'web-context-cancelled',
    ];

    for (final code in codes) {
      test('$code is white-labelled', () {
        // Each carries hostile provider prose to prove it is never echoed.
        final failure = AuthErrorMapper.toFailure(
          FirebaseAuthException(
            code: code,
            message: 'FIREBASE INTERNAL: identitytoolkit rejected the OAuth '
                'token; see https://console.firebase.google.com',
          ),
        );
        _expectClean(failure, because: code);
      });
    }
  });

  group('unknown and non-provider errors still cannot leak', () {
    test('an unrecognised code falls back to Help24 copy', () {
      final failure = AuthErrorMapper.toFailure(
        FirebaseAuthException(
          code: 'some-code-invented-in-a-future-sdk',
          message: 'Supabase PostgREST returned 500 from onrender.com',
        ),
        flow: AuthFlow.signIn,
      );
      _expectClean(failure, because: 'unknown code');
      expect(failure.message, "We couldn't sign you in just now. Please try again.");
    });

    test('a raw string error cannot pass through', () {
      final failure = AuthErrorMapper.toFailure(
        'PostgrestException: JWT expired at supabase.co',
        flow: AuthFlow.signIn,
      );
      _expectClean(failure, because: 'raw string');
    });

    test('null error yields the generic fallback', () {
      _expectClean(AuthErrorMapper.toFailure(null), because: 'null');
    });

    test('timeouts read as slowness, not as failure', () {
      final failure = AuthErrorMapper.toFailure(TimeoutException('x'));
      _expectClean(failure, because: 'timeout');
      expect(failure.title, 'That took too long');
    });

    test('connectivity errors are recognised from any wording', () {
      for (final raw in [
        'SocketException: Failed host lookup',
        'Connection refused',
        'network is unreachable',
      ]) {
        final failure = AuthErrorMapper.toFailure(raw, flow: AuthFlow.signIn);
        expect(failure.title, 'No internet connection', reason: raw);
        _expectClean(failure, because: raw);
      }
    });
  });

  group('recovery actions — the promise that no flow dead-ends', () {
    test('no account offers Create account', () {
      final f = AuthErrorMapper.toFailure(
          FirebaseAuthException(code: 'user-not-found'));
      expect(f.recovery, AuthRecovery.createAccount);
      expect(f.actionLabel, 'Create account');
    });

    test('existing account offers Sign in', () {
      final f = AuthErrorMapper.toFailure(
          FirebaseAuthException(code: 'email-already-in-use'));
      expect(f.recovery, AuthRecovery.signIn);
      expect(f.actionLabel, 'Sign in instead');
    });

    // CHANGED, deliberately — this test used to assert `resetPassword`, and
    // that assertion is the incident. With enumeration protection on, the
    // provider collapses "wrong password", "no such user" AND "this account
    // has no password at all" into `invalid-credential`. The third case is a
    // Google account, where a password reset cannot succeed: the email arrives
    // and answers a question the user was not asking, and the flow dead-ends.
    //
    // "Forgot password?" is a permanent affordance on the password step, so the
    // recovery button carries the door the user cannot otherwise reach.
    test('rejected credentials offer the other sign-in door', () {
      for (final code in ['invalid-credential', 'wrong-password', 'invalid-login-credentials']) {
        final f = AuthErrorMapper.toFailure(FirebaseAuthException(code: code));
        expect(f.recovery, AuthRecovery.useGoogle, reason: code);
        expect(f.actionLabel, 'Continue with Google', reason: code);
      }
    });

    test('a rejected sign-in never asserts the password was simply wrong', () {
      final f = AuthErrorMapper.toFailure(
          FirebaseAuthException(code: 'invalid-credential'));
      // It may not claim to know which of the three causes applied.
      expect(f.message.toLowerCase(), contains('google'));
    });

    test('linking failures never tell a signed-in user to sign in', () {
      for (final code in [
        'provider-already-linked',
        'credential-already-in-use',
        'email-already-in-use',
      ]) {
        final f = AuthErrorMapper.toFailure(
          FirebaseAuthException(code: code),
          flow: AuthFlow.linkMethod,
        );
        expect(f.recovery, AuthRecovery.none, reason: code);
        expect(f.message.toLowerCase(), isNot(contains('sign in to')), reason: code);
      }
    });

    test('email-already-in-use still routes to sign-in OUTSIDE the link flow', () {
      final f = AuthErrorMapper.toFailure(
        FirebaseAuthException(code: 'email-already-in-use'),
        flow: AuthFlow.signUp,
      );
      expect(f.recovery, AuthRecovery.signIn);
    });

    test('expired code offers a fresh one', () {
      final f = AuthErrorMapper.toFailure(
          FirebaseAuthException(code: 'session-expired'));
      expect(f.recovery, AuthRecovery.resendCode);
    });

    test('an unusable verification session restarts the phone step', () {
      final f = AuthErrorMapper.toFailure(
          FirebaseAuthException(code: 'invalid-verification-id'));
      expect(f.recovery, AuthRecovery.restartPhone);
    });
  });

  group('isSafeToShow — the deny-list backstop', () {
    test('rejects vendor and protocol vocabulary', () {
      for (final s in [
        'Firebase error occurred',
        'Supabase returned an error',
        'Your JWT expired',
        'reCAPTCHA verification failed',
        'OAuth redirect failed',
        'Request failed with status code 500',
        'https://help24-24410.firebaseapp.com/__/auth/action',
      ]) {
        expect(AuthErrorMapper.isSafeToShow(s), isFalse, reason: s);
      }
    });

    test('accepts ordinary human sentences', () {
      expect(AuthErrorMapper.isSafeToShow('That code has expired.'), isTrue);
      expect(AuthErrorMapper.isSafeToShow('Check your password.'), isTrue);
    });

    test('rejects empty and overlong text', () {
      expect(AuthErrorMapper.isSafeToShow(''), isFalse);
      expect(AuthErrorMapper.isSafeToShow(null), isFalse);
      expect(AuthErrorMapper.isSafeToShow('a' * 200), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // Password reset must not answer "does this account exist?"
  // ═══════════════════════════════════════════════════════════════════════
  //
  // The reset sheet is unauthenticated: anyone can open Help24 and type any
  // address into it. If the reply differs between a registered address and an
  // unregistered one, the form becomes a tool for enumerating Help24's users —
  // and that list is the raw material for a phishing campaign against them.
  //
  // TWO LAYERS ENFORCE THIS, ON PURPOSE.
  //   1. AuthService.sendPasswordResetEmail converts `user-not-found` into a
  //      SUCCESS, so the sheet shows the same "if that address has an account"
  //      copy either way.
  //   2. The mapper refuses to produce existence-specific copy for this flow
  //      at all, so a future reset path that forgets rule 1 still cannot leak.
  //
  // These cover layer 2, which is the one with no other test.

  group('password reset does not reveal whether an account exists', () {
    /// Words that would answer the attacker's question either way.
    const existenceTells = <String>[
      'no account',
      "couldn't find",
      'could not find',
      'not found',
      'does not exist',
      "doesn't exist",
      'not registered',
      'already have an account',
      'already registered',
      'unregistered',
    ];

    void expectSaysNothingAboutExistence(AuthFailure failure, String because) {
      final text = '${failure.title} ${failure.message}'.toLowerCase();
      for (final tell in existenceTells) {
        expect(text.contains(tell), isFalse,
            reason: 'leaked account existence via "$tell" ($because): '
                '${failure.title} — ${failure.message}');
      }
      // A recovery button is a tell too: "Create account" on an unregistered
      // address answers the question without using any of the words above.
      expect(failure.recovery, isNot(AuthRecovery.createAccount),
          reason: 'createAccount recovery reveals the address is free ($because)');
      expect(failure.recovery, isNot(AuthRecovery.signIn),
          reason: 'signIn recovery reveals the address is taken ($because)');
    }

    test('an unregistered address produces no existence-specific copy', () {
      final failure = AuthErrorMapper.toFailure(
        FirebaseAuthException(code: 'user-not-found'),
        flow: AuthFlow.passwordReset,
      );
      expectSaysNothingAboutExistence(failure, 'user-not-found');
      _expectClean(failure, because: 'reset for an unknown address');
      // And it is still a usable message, not a blank.
      expect(failure.title.trim(), isNotEmpty);
      expect(failure.message.trim(), isNotEmpty);
    });

    test('a registered address that fails transport looks identical', () {
      // The point of the property: the two cases must be indistinguishable.
      // `internal-error` stands in for a genuine transport failure on an
      // address that DOES exist.
      final missing = AuthErrorMapper.toFailure(
        FirebaseAuthException(code: 'user-not-found'),
        flow: AuthFlow.passwordReset,
      );
      final transport = AuthErrorMapper.toFailure(
        FirebaseAuthException(code: 'internal-error'),
        flow: AuthFlow.passwordReset,
      );
      expect(missing.title, transport.title);
      expect(missing.message, transport.message);
      expect(missing.recovery, transport.recovery);
    });

    test('no reset-flow failure ever offers an existence-revealing recovery', () {
      // Every code the reset call can realistically raise.
      for (final code in <String>[
        'user-not-found',
        'user-disabled',
        'invalid-email',
        'missing-email',
        'too-many-requests',
        'network-request-failed',
        'internal-error',
        'operation-not-allowed',
        'unauthorized-continue-uri',
        'invalid-continue-uri',
        'missing-continue-uri',
        'invalid-dynamic-link-domain',
        'quota-exceeded',
        'a-code-invented-in-2027',
      ]) {
        final failure = AuthErrorMapper.toFailure(
          FirebaseAuthException(code: code),
          flow: AuthFlow.passwordReset,
        );
        expect(failure.recovery, isNot(AuthRecovery.createAccount), reason: code);
        _expectClean(failure, because: 'reset flow: $code');
      }
    });

    test('sign-in still tells a user their address has no account', () {
      // The protection is scoped, not blanket. On the sign-in path the user is
      // acting on an address they intend to use, and "create an account" is
      // the only useful next step — removing it there would be a worse product
      // for no security gain, because sign-in already reveals as much.
      final failure = AuthErrorMapper.toFailure(
        FirebaseAuthException(code: 'user-not-found'),
        flow: AuthFlow.signIn,
      );
      expect(failure.recovery, AuthRecovery.createAccount);
      expect(failure.title, 'No account yet');
    });
  });
}

/// Added with the confirmation-email work. See
/// `lib/services/email_verification_cooldown.dart` for the whole diagnosis.
void _verificationCopy() {
  group('confirming an email address', () {
    test('every flow, including the new one, stays free of vendor words', () {
      for (final flow in AuthFlow.values) {
        for (final code in <String>[
          'too-many-requests',
          'user-disabled',
          'operation-not-allowed',
          'network-request-failed',
          'internal-error',
          'a-code-invented-in-2027',
        ]) {
          _expectClean(
            AuthErrorMapper.toFailure(
              FirebaseAuthException(code: code),
              flow: flow,
            ),
            because: '${flow.name}: $code',
          );
        }
      }
    });

    test('a throttled resend is not reported as the user getting it wrong', () {
      // The reported symptom. The user tapped a button two or three times,
      // every request SUCCEEDED, and the provider throttled the send. Telling
      // them "too many attempts, for your security" reads as an accusation for
      // doing the thing the screen asked for — and omits the fact that helps:
      // the emails were sent, so the inbox is where to look.
      final failure = AuthErrorMapper.toFailure(
        FirebaseAuthException(code: 'too-many-requests'),
        flow: AuthFlow.verifyEmail,
      );
      expect(failure.title, isNot(contains('Too many attempts')));
      expect(failure.message.toLowerCase(), contains('spam'));
      _expectClean(failure, because: 'throttled verification resend');
    });

    test('signing in still says "too many attempts", because it is', () {
      // The same code, a genuinely different situation: repeated failures
      // against a credential. The pause there IS the defence working, and
      // softening it would misdescribe a security event.
      final failure = AuthErrorMapper.toFailure(
        FirebaseAuthException(code: 'too-many-requests'),
        flow: AuthFlow.signIn,
      );
      expect(failure.title, 'Too many attempts');
    });

    test('a failed send never implies the session is at risk', () {
      // The user is signed in and stays signed in. Copy that hints otherwise
      // sends people back to a sign-in screen they do not need.
      final failure = AuthErrorMapper.toFailure(
        TimeoutException('slow'),
        flow: AuthFlow.verifyEmail,
      );
      _expectClean(failure, because: 'verification timeout');
      expect(failure.recovery, AuthRecovery.none);
    });
  });

  group('support routes point somewhere that works', () {
    test('no auth failure hands the user a mailbox that cannot receive', () {
      // help24.co.ke publishes no MX record, so mail to support@help24.co.ke
      // falls back to the web host and times out. Until inbound mail exists,
      // a locked-out user must be sent to the support PAGE instead.
      for (final flow in AuthFlow.values) {
        for (final code in <String>[
          'user-disabled',
          'operation-not-allowed',
          'not-configured',
          'unsupported-first-factor',
        ]) {
          final failure = AuthErrorMapper.toFailure(
            FirebaseAuthException(code: code),
            flow: flow,
          );
          expect(failure.message, isNot(contains('@')),
              reason: '${flow.name}/$code offers an email address');
        }
      }
    });
  });
}
