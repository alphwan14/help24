/// Which surface actually decides where a provider's earnings are sent.
///
/// Exists because of a real-device finding (launch-readiness-verification-report
/// §M4): Account → "Payment Settings" wrote `users.phone_number` under the copy
/// *"This number is used for M-Pesa payments and payouts"*, while Business →
/// "Payout Destinations" claimed to be the authoritative payout system. Two
/// screens, one job, and a provider could reasonably believe either.
///
/// The honest answer is that it depends on a backend flag, and the app must not
/// guess. `MpesaService.releasePayout` (backend `mpesa.service.ts`) resolves the
/// destination like this:
///
///   * `PAYOUT_DESTINATIONS_ENABLED=true`  → the verified destination decides,
///     and a provider without one is REFUSED. The profile number is ignored
///     entirely — "do not silently fall back to the profile number, which is
///     the entire behaviour this work exists to remove."
///   * flag off → the B2C payout settles to `users.phone_number`, i.e. the
///     legacy Payment Settings number genuinely is the payout destination.
///
/// So the legacy screen's copy is currently ACCURATE and becomes a dangerous
/// lie the moment the flag flips. Rather than hard-code either answer, the app
/// reads the same signal it already uses everywhere else — `/payout-destinations`
/// answers 503 while the feature is off — and says only what is true right now.
///
/// This adds no backend surface. It is a client-side reading of an existing
/// production signal.
library;

enum PayoutAuthority {
  /// Payout Destinations is live. It ALONE decides where earnings go; the
  /// profile number has no payout role and the UI must say so.
  destinations,

  /// Payout Destinations has not been rolled out yet. The backend still
  /// settles B2C to the profile number, so that number really does govern
  /// payouts and the UI must not deny it.
  profileNumber,

  /// The probe failed (offline, 5xx, auth). Claim nothing about payouts —
  /// a wrong answer here either strands a provider's money or invites them to
  /// configure a number that will be ignored.
  unknown,
}

/// Resolve from the outcome of a `/payout-destinations` read.
///
/// [reachable] is false when the request could not be completed at all
/// (offline, timeout, non-503 error). [featureUnavailable] is the backend's
/// 503 — the documented "flag is off" answer, surfaced by
/// `PayoutException.featureUnavailable`.
///
/// Order matters: unreachable outranks everything, because a failed fetch must
/// never be published as a definite state.
PayoutAuthority resolvePayoutAuthority({
  required bool reachable,
  required bool featureUnavailable,
}) {
  if (!reachable) return PayoutAuthority.unknown;
  if (featureUnavailable) return PayoutAuthority.profileNumber;
  return PayoutAuthority.destinations;
}

/// What the legacy payment-number screen may truthfully say about payouts.
///
/// Returning null means "say nothing" — the deliberate choice for [unknown],
/// so an offline provider is never told their earnings go somewhere they don't.
String? payoutNoteFor(PayoutAuthority authority) => switch (authority) {
      PayoutAuthority.destinations =>
        'Payouts are NOT sent here. Your earnings go to the number you verified '
            'under Business → Payout Destinations.',
      PayoutAuthority.profileNumber =>
        'Payouts currently go to this number too. Verified payout destinations '
            'are being rolled out — once available, they take over.',
      PayoutAuthority.unknown => null,
    };
