import 'error_mapper.dart';

enum _MpesaOutcome { cancelled, wrongPin, insufficient, busy, unreachable, expired, other }

/// M-PESA FAILURES, IN WORDS FOR THE PERSON PAYING.
///
/// WHY THIS IS ONE FILE
/// --------------------
/// Two flows take M-Pesa payments — Secure Service (payment_screen.dart) and
/// Promote Business (promote_listing_flow_screen.dart, plus its Payments
/// history) — and each grew its own reading of Daraja's text. Every one of
/// them ended in a pass-through: "if it is short, show it". Daraja's text is
/// written for integrators, so users read
///
///   "The initiator information is invalid."   (for a wrong PIN)
///   "Unable to lock subscriber, a transaction is already in process for the
///    current subscriber"
///   'Configuration key "MPESA_PASSKEY" does not exist'   (a server fault)
///
/// and, from the start-payment call, "Post 3f2a…-uuid not found.". Nothing in
/// this file passes provider or server text through; what it does not
/// recognise it answers in Help24's own words.
///
/// Pure Dart, so the copy is testable without a screen — see
/// test/error_mapper_test.dart.
class MpesaFailureCopy {
  MpesaFailureCopy._();

  static const String notCompleted = 'Payment was not completed. Please try again.';

  /// Why an STK prompt that reached the payer's phone did not end in a
  /// payment, from the ResultDesc Daraja reported (stored as `failure_reason`).
  ///
  /// Daraja result codes this recognises:
  ///   1          insufficient balance
  ///   1001       another M-Pesa transaction is in progress for this number
  ///   1019       the transaction expired
  ///   1031/1032  cancelled on the phone
  ///   1037       DS timeout — the phone could not be reached
  ///   2001       wrong PIN, reported as "The initiator information is invalid."
  static String forResult(String? resultDesc) => switch (_classify(resultDesc)) {
        _MpesaOutcome.cancelled =>
          "You cancelled the M-Pesa request. Try again when you're ready.",
        _MpesaOutcome.wrongPin =>
          'The M-Pesa PIN entered was incorrect. Please try again.',
        _MpesaOutcome.insufficient =>
          "Your M-Pesa balance wasn't enough for this payment. Top up and try again.",
        _MpesaOutcome.busy =>
          'Another M-Pesa payment is in progress on this phone. Wait a moment, then try again.',
        _MpesaOutcome.unreachable =>
          "M-Pesa couldn't reach your phone. Make sure it's on and has network, then try again.",
        _MpesaOutcome.expired =>
          'The M-Pesa request expired before it was completed. Please try again.',
        _MpesaOutcome.other => notCompleted,
      };

  /// The same outcome as a short label, for a payment HISTORY row — where the
  /// payment is in the past and "please try again" would be advice about an
  /// attempt the user is no longer making.
  static String summary(String? resultDesc) => switch (_classify(resultDesc)) {
        _MpesaOutcome.cancelled => 'Cancelled on the phone',
        _MpesaOutcome.wrongPin => 'Wrong M-Pesa PIN',
        _MpesaOutcome.insufficient => 'Insufficient M-Pesa balance',
        _MpesaOutcome.busy => 'Another M-Pesa payment was in progress',
        _MpesaOutcome.unreachable => "M-Pesa couldn't reach the phone",
        _MpesaOutcome.expired => 'M-Pesa request expired',
        _MpesaOutcome.other => 'Payment not completed',
      };

  static _MpesaOutcome _classify(String? resultDesc) {
    final s = (resultDesc ?? '').toLowerCase().trim();
    if (s.isEmpty) return _MpesaOutcome.other;
    // A result code counts only when the stored reason IS the code. Matched as
    // a substring, the server fault '…"errorCode":"500.001.1001"…' read as
    // 1001 — "another payment is in progress" — for a failure on our side.
    final code = RegExp(r'^\d+$').hasMatch(s) ? s : null;
    if (s.contains('cancel') || code == '1031' || code == '1032') {
      return _MpesaOutcome.cancelled;
    }
    // "The initiator information is invalid." is Daraja's text for 2001 — a
    // wrong PIN — and contains neither "PIN" nor the code, which is how it
    // used to slip past the wrong-PIN rule and reach users verbatim.
    if (s.contains('wrong pin') ||
        s.contains('invalid pin') ||
        s.contains('initiator information') ||
        code == '2001') {
      return _MpesaOutcome.wrongPin;
    }
    if (s.contains('insufficient') || code == '1') return _MpesaOutcome.insufficient;
    if (s.contains('unable to lock') ||
        s.contains('already in process') ||
        code == '1001') {
      return _MpesaOutcome.busy;
    }
    if (s.contains('cannot be reached') ||
        s.contains('unreachable') ||
        s.contains('ds timeout') ||
        code == '1037') {
      return _MpesaOutcome.unreachable;
    }
    if (s.contains('expired') || code == '1019') return _MpesaOutcome.expired;
    return _MpesaOutcome.other;
  }

  /// Why a payment could not be STARTED — [error] is what the start-payment
  /// call threw (an MpesaException, a PromotionException, or a transport
  /// failure).
  static String forInitiation(Object? error) {
    final category = ErrorMapper.classify(error);
    // No response came back, so the prompt may or may not be on its way — say
    // so rather than claiming nothing happened. A retry is safe: the backend
    // answers a second attempt with "already in progress" (409).
    if (category == ErrorCategory.networkTimeout) {
      return "We didn't get a response in time. If an M-Pesa prompt appears "
          'on your phone, complete it — otherwise try again.';
    }
    if (category == ErrorCategory.networkOffline ||
        category == ErrorCategory.serverUnavailable) {
      return ErrorMapper.toMessage(error, context: ErrorContext.payment);
    }

    final s = _messageOf(error).toLowerCase();
    // State first: "A payment is already in progress — check your phone for
    // the M-Pesa prompt." mentions a phone, and is not about a phone number.
    if (s.contains('already been made')) {
      return 'This has already been paid for.';
    }
    // A DIFFERENT state from "already paid": a prompt is waiting on the phone.
    if (s.contains('already in progress')) {
      return 'A payment is already in progress. Check your phone for the M-Pesa prompt.';
    }
    // The PROVIDER's number is missing — checked before the payer's rule,
    // which also matches "M-Pesa number" and used to send the payer to fix
    // their own profile for a problem on the other side.
    if (s.contains('provider') && s.contains('m-pesa number')) {
      return "The provider hasn't added their M-Pesa number yet. Ask them to "
          'update their profile, then try again.';
    }
    if (s.contains('m-pesa number') ||
        s.contains('phone number') ||
        s.contains('valid phone') ||
        s.contains('invalid phone')) {
      return 'Add a valid M-Pesa number in Profile → Payment Number, then try again.';
    }
    if (s.contains('no provider')) {
      return 'Choose a provider for this job before paying.';
    }
    if (s.contains('below the minimum')) {
      return "This price is below M-Pesa's minimum payment of KES 100.";
    }
    if (s.contains('daraja') || s.contains('stk')) {
      return "M-Pesa isn't responding right now. Please try again shortly.";
    }
    return ErrorMapper.toMessage(error, context: ErrorContext.payment);
  }

  static String _messageOf(Object? error) {
    if (error == null) return '';
    try {
      final dynamic e = error;
      final message = e.message;
      if (message is String) return message;
    } catch (_) {
      // No `.message` — use the text form.
    }
    return error.toString();
  }
}
