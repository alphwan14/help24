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

    test('bad credentials offer a password reset', () {
      final f = AuthErrorMapper.toFailure(
          FirebaseAuthException(code: 'invalid-credential'));
      expect(f.recovery, AuthRecovery.resetPassword);
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
}
