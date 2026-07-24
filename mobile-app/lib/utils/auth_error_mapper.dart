import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../config/app_urls.dart';

/// What the user can usefully DO about a failure. The auth UI renders this as
/// a real button, which is how a flow stops being a dead end.
///
/// The old screens showed sentences like "No account found with this email.
/// Sign up instead?" — a question with no way to answer it. Every failure that
/// has an obvious next move now carries it as data.
enum AuthRecovery {
  /// Nothing to offer beyond dismissing and retrying.
  none,

  /// The email has no account → offer "Create account", carrying the email.
  createAccount,

  /// The email already has an account → offer "Sign in", carrying the email.
  signIn,

  /// Credentials were rejected → offer "Reset password".
  resetPassword,

  /// The code was wrong or stale → offer "Send a new code".
  resendCode,

  /// Start the phone step over (the verification session is unusable).
  restartPhone,

  /// A device/app integrity problem the user can only fix by updating.
  updateApp,

  /// Only Help24 Support can move this forward.
  contactSupport,
}

/// A failure rendered for a human: a headline, one actionable sentence, and
/// optionally the single button that resolves it.
@immutable
class AuthFailure {
  final String title;
  final String message;
  final AuthRecovery recovery;

  const AuthFailure({
    required this.title,
    required this.message,
    this.recovery = AuthRecovery.none,
  });

  /// Label for the recovery button, or null when there is nothing to offer.
  String? get actionLabel {
    switch (recovery) {
      case AuthRecovery.createAccount:
        return 'Create account';
      case AuthRecovery.signIn:
        return 'Sign in instead';
      case AuthRecovery.resetPassword:
        return 'Reset password';
      case AuthRecovery.resendCode:
        return 'Send a new code';
      case AuthRecovery.restartPhone:
        return 'Start again';
      case AuthRecovery.updateApp:
        return 'Get help';
      case AuthRecovery.contactSupport:
        return 'Contact support';
      case AuthRecovery.none:
        return null;
    }
  }
}

/// The single translation layer between the identity provider and the user.
///
/// THE RULE THIS FILE EXISTS TO ENFORCE
/// ------------------------------------
/// A provider error message is written for the developer who integrated the
/// SDK, not for a person signing in on a phone in Nairobi. Before this file,
/// both auth mappers ended with `return e.message ?? '…'` — a default branch
/// that forwarded provider prose verbatim, which is exactly how users came to
/// read things like:
///
///   "This request is missing a valid app identifier, meaning that Play
///    Integrity checks and reCAPTCHA checks were unsuccessful."
///   "Unable to process request due to missing initial state. This may happen
///    if browser sessionStorage is inaccessible or accidentally cleared."
///
/// Those sentences name three vendor systems, blame a browser API the user has
/// never heard of, and offer no next step.
///
/// So: [toFailure] never returns provider text. Codes are mapped explicitly;
/// anything unrecognised falls back to Help24 copy, and [_isSafeToShow] is a
/// deny-list backstop so that a future SDK version inventing a new message
/// still cannot leak. The real error always goes to [debugPrint] instead —
/// engineers keep every detail the user must never see.
class AuthErrorMapper {
  AuthErrorMapper._();

  /// Map any error thrown during an auth operation to user-facing copy.
  static AuthFailure toFailure(Object? error, {AuthFlow flow = AuthFlow.generic}) {
    _log(error, flow);

    if (error is FirebaseAuthException) return _fromAuthCode(error, flow);
    if (error is TimeoutException) return _timeout();

    final raw = (error?.toString() ?? '').toLowerCase();
    if (_isConnectivity(raw)) return _offline();
    if (_isIntegrity(raw)) return _integrity();
    if (_isBrowserHandoff(raw)) return _browserHandoff();

    return _generic(flow);
  }

  /// Convenience for call sites that only need the sentence.
  static String toMessage(Object? error, {AuthFlow flow = AuthFlow.generic}) =>
      toFailure(error, flow: flow).message;

  // ─── Provider code mapping ──────────────────────────────────────────────
  //
  // Every branch returns Help24-authored copy. `e.message` is deliberately
  // never read: it is logged, never shown.

  static AuthFailure _fromAuthCode(FirebaseAuthException e, AuthFlow flow) {
    switch (e.code) {
      // ── Account existence ────────────────────────────────────────────
      case 'user-not-found':
        return const AuthFailure(
          title: 'No account yet',
          message: "We couldn't find a Help24 account with this email.",
          recovery: AuthRecovery.createAccount,
        );
      case 'email-already-in-use':
        return const AuthFailure(
          title: 'You already have an account',
          message: 'This email is already registered with Help24.',
          recovery: AuthRecovery.signIn,
        );

      // ── Credentials ──────────────────────────────────────────────────
      //
      // With email-enumeration protection enabled, the provider collapses
      // "no such user" and "wrong password" into `invalid-credential` on
      // purpose — so the copy must stay honest about the ambiguity instead of
      // asserting the password was wrong.
      case 'wrong-password':
        return const AuthFailure(
          title: 'Incorrect password',
          message: "That password doesn't match this account.",
          recovery: AuthRecovery.resetPassword,
        );
      case 'invalid-credential':
      case 'invalid-login-credentials':
        return const AuthFailure(
          title: "That didn't work",
          message: 'Check your email and password and try again.',
          recovery: AuthRecovery.resetPassword,
        );
      case 'invalid-email':
        return const AuthFailure(
          title: 'Check your email',
          message: "That email address doesn't look right.",
        );
      case 'weak-password':
        return const AuthFailure(
          title: 'Choose a stronger password',
          message: 'Use at least 8 characters, with a mix of letters and numbers.',
        );

      // ── Account state ────────────────────────────────────────────────
      case 'user-disabled':
        return AuthFailure(
          title: 'Account unavailable',
          message: 'This account has been suspended. ${AppSupport.email} can help.',
          recovery: AuthRecovery.contactSupport,
        );
      case 'requires-recent-login':
        return const AuthFailure(
          title: 'Please sign in again',
          message: 'For your security, sign in again to make this change.',
        );
      case 'account-exists-with-different-credential':
      case 'credential-already-in-use':
        return const AuthFailure(
          title: 'Try another way in',
          message:
              'This email is already registered with Help24 using a different '
              'sign-in method. Use the one you set up first.',
          recovery: AuthRecovery.signIn,
        );

      // ── Phone / OTP ──────────────────────────────────────────────────
      case 'invalid-phone-number':
      case 'missing-phone-number':
        return const AuthFailure(
          title: 'Check your number',
          message: 'Enter your number without the leading 0 — for example 712 345 678.',
        );
      case 'invalid-verification-code':
        return const AuthFailure(
          title: 'Incorrect code',
          message: "That code isn't right. Check the SMS and try again.",
        );
      case 'session-expired':
      case 'code-expired':
        return const AuthFailure(
          title: 'Code expired',
          message: 'That code has expired. We can send you a new one.',
          recovery: AuthRecovery.resendCode,
        );
      case 'invalid-verification-id':
      case 'missing-verification-id':
        return const AuthFailure(
          title: 'Let’s start over',
          message: 'This verification is no longer valid. Enter your number again.',
          recovery: AuthRecovery.restartPhone,
        );
      case 'quota-exceeded':
        return const AuthFailure(
          title: 'Try again shortly',
          message:
              "We couldn't send a code right now. Please try again in a few minutes.",
        );

      // ── Device / app integrity ───────────────────────────────────────
      //
      // The provider's own wording here names Play Integrity and reCAPTCHA.
      // The user cannot act on either word; what they CAN do is check their
      // connection and update the app.
      case 'missing-client-identifier':
      case 'app-not-authorized':
      case 'invalid-app-credential':
      case 'captcha-check-failed':
      case 'web-context-cancelled':
      case 'web-context-already-presented':
        return _integrity();

      // ── Transport ────────────────────────────────────────────────────
      case 'network-request-failed':
        return _offline();
      case 'too-many-requests':
        return const AuthFailure(
          title: 'Too many attempts',
          message: 'For your security, please wait a few minutes and try again.',
        );

      // ── Configuration (should never reach a user in production) ───────
      case 'operation-not-allowed':
      case 'not-configured':
      case 'unsupported-first-factor':
        return AuthFailure(
          title: 'Not available right now',
          message:
              "This way of signing in isn't available at the moment. "
              'Try another option, or contact ${AppSupport.email}.',
          recovery: AuthRecovery.contactSupport,
        );

      default:
        // Unknown code: classify from the raw text WITHOUT showing it.
        final raw = '${e.code} ${e.message ?? ''}'.toLowerCase();
        if (_isConnectivity(raw)) return _offline();
        if (_isIntegrity(raw)) return _integrity();
        if (_isBrowserHandoff(raw)) return _browserHandoff();
        return _generic(flow);
    }
  }

  // ─── Canonical Help24 failures ──────────────────────────────────────────

  static AuthFailure _offline() => const AuthFailure(
        title: 'No internet connection',
        message: "We couldn't reach Help24. Check your connection and try again.",
      );

  static AuthFailure _timeout() => const AuthFailure(
        title: 'That took too long',
        message: 'Your connection seems slow right now. Please try again.',
      );

  /// Replaces the provider's Play Integrity / reCAPTCHA sentence.
  static AuthFailure _integrity() => const AuthFailure(
        title: "We couldn't verify your device",
        message:
            "We couldn't verify your device right now. Check your internet "
            'connection and try again. If this keeps happening, update Help24 '
            'from the Play Store.',
        recovery: AuthRecovery.updateApp,
      );

  /// Replaces "missing initial state … browser sessionStorage is inaccessible".
  static AuthFailure _browserHandoff() => const AuthFailure(
        title: "We couldn't finish signing you in",
        message: "We couldn't complete sign in. Please return to Help24 and try again.",
      );

  static AuthFailure _generic(AuthFlow flow) {
    switch (flow) {
      case AuthFlow.signIn:
        return const AuthFailure(
          title: "We couldn't sign you in",
          message: "We couldn't sign you in just now. Please try again.",
        );
      case AuthFlow.signUp:
        return const AuthFailure(
          title: "We couldn't create your account",
          message: "We couldn't finish creating your account. Please try again.",
        );
      case AuthFlow.sendCode:
        return const AuthFailure(
          title: "We couldn't send your code",
          message: "We couldn't send your code just now. Please try again.",
        );
      case AuthFlow.verifyCode:
        return const AuthFailure(
          title: "We couldn't verify that code",
          message: "We couldn't check your code just now. Please try again.",
        );
      case AuthFlow.passwordReset:
        return const AuthFailure(
          title: "We couldn't send that email",
          message: "We couldn't send your reset email just now. Please try again.",
        );
      case AuthFlow.generic:
        return const AuthFailure(
          title: 'Something went wrong',
          message: 'Something went wrong. Please try again.',
        );
    }
  }

  // ─── Classification on raw text (never shown, only matched) ─────────────

  static bool _isConnectivity(String s) =>
      s.contains('network') ||
      s.contains('failed host lookup') ||
      s.contains('unreachable') ||
      s.contains('connection refused') ||
      s.contains('connection closed') ||
      s.contains('connection reset') ||
      s.contains('socketexception') ||
      s.contains('handshake') ||
      s.contains('timed out') ||
      s.contains('timeout');

  static bool _isIntegrity(String s) =>
      s.contains('play integrity') ||
      s.contains('playintegrity') ||
      s.contains('recaptcha') ||
      s.contains('app identifier') ||
      s.contains('app-not-authorized') ||
      s.contains('safetynet') ||
      s.contains('app check') ||
      s.contains('appcheck') ||
      s.contains('attestation') ||
      s.contains('device verification');

  static bool _isBrowserHandoff(String s) =>
      s.contains('sessionstorage') ||
      s.contains('missing initial state') ||
      s.contains('storage is inaccessible') ||
      s.contains('popup') ||
      s.contains('redirect_uri') ||
      s.contains('oauth') ||
      s.contains('saml') ||
      s.contains('idp') ||
      s.contains('web-storage-unsupported');

  /// Deny-list backstop. Exposed for tests and for any future call site that
  /// is tempted to pass provider text through: if this returns false, the
  /// string must not reach a user.
  ///
  /// Deliberately paranoid — it is far better to show generic Help24 copy than
  /// to teach a user the word "Firestore".
  @visibleForTesting
  static bool isSafeToShow(String? text) => _isSafeToShow(text);

  static bool _isSafeToShow(String? text) {
    if (text == null) return false;
    final s = text.trim();
    if (s.isEmpty || s.length > 160) return false;
    final lower = s.toLowerCase();
    const banned = <String>[
      // Vendors and their surfaces
      'firebase', 'firestore', 'firebaseapp', 'web.app', 'supabase',
      'postgrest', 'postgres', 'render', 'onrender', 'google cloud', 'gcp',
      'identity toolkit', 'identitytoolkit', 'identity platform',
      'google provider', 'googleapis', 'play integrity', 'playintegrity',
      'recaptcha', 'safetynet', 'app check', 'appcheck',
      // Protocol / implementation vocabulary
      'oauth', 'saml', 'oidc', 'idp', 'jwt', 'token', 'api key', 'apikey',
      'sessionstorage', 'localstorage', 'cors', 'http', 'https', 'url',
      'endpoint', 'sdk', 'client id', 'credential', 'rls', 'sql',
      // Debug shrapnel
      'exception', 'stack', 'null', 'undefined', 'error:', 'status code',
      'statuscode', '{', '}', '[', ']', 'dart:', 'flutter', '#0',
    ];
    for (final marker in banned) {
      if (lower.contains(marker)) return false;
    }
    return true;
  }

  static void _log(Object? error, AuthFlow flow) {
    if (error == null) return;
    // Developer-only. Never surfaced. Includes the provider's own wording so
    // an engineer can still diagnose exactly what the SDK reported.
    if (error is FirebaseAuthException) {
      debugPrint('[AUTH][${flow.name}] code=${error.code} detail=${error.message}');
    } else {
      debugPrint('[AUTH][${flow.name}] ${error.runtimeType}: $error');
    }
  }
}

/// Which operation failed — used only to pick the most reassuring fallback.
enum AuthFlow {
  generic,
  signIn,
  signUp,
  sendCode,
  verifyCode,
  passwordReset,
}
