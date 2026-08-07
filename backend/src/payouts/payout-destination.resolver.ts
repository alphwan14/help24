/**
 * WHERE THE MONEY GOES — decided once, here, and nowhere else.
 *
 * This file is deliberately PURE: no database, no HTTP, no clock beyond what is
 * passed in. Everything that decides a payout destination is a total function
 * over explicit inputs, so every rule below is testable without a live escrow,
 * and so a reviewer can read the entire decision in one place.
 *
 * THE RULE
 * --------
 *   1. If the escrow carries a frozen destination, pay THAT. Always. It was
 *      captured when the parties agreed and is not open to revision.
 *   2. Otherwise the escrow predates the snapshot. During the transition, fall
 *      back to the provider's current payable destination, and SAY SO in the
 *      returned source so the fallback is countable rather than invisible.
 *   3. Once the transition is over (`allowLegacyFallback = false`), refuse.
 *
 * Rule 1 is the whole point. Re-deriving a destination at payout time is what
 * let a profile edit redirect money that had already been earned.
 */

/** Channels money can travel over. Extending this is a new value, not a new table. */
export type PayoutChannel = 'mpesa';

/**
 * LIFECYCLE ONLY — can this destination receive money?
 *
 * There is no `legacy` here any more. "Usable but unproven" was never a
 * lifecycle state; it was a statement about PROVENANCE wearing a status's
 * clothing, and it could not tell an admin-asserted destination from an
 * OTP-proven one. That question now belongs to `verification_method`.
 */
export type PayoutDestinationStatus = 'pending' | 'active' | 'retired';

/**
 * PROVENANCE — how a destination came to be trusted. Permanent, write-once.
 *
 * These are not interchangeable. `otp` means the provider demonstrated control
 * of the destination itself; `migration` means it was copied out of a profile
 * field and nobody proved anything. A payout dispute reads this field first.
 */
export type VerificationMethod =
  | 'otp'
  | 'migration'
  | 'admin'
  | 'support'
  | 'future_kyc';

/**
 * Methods that count as the provider having PROVEN control.
 *
 * Phase 5 accepts only these. Everything else is trusted by assertion — fine
 * during a transition, not fine forever, and the distinction is exactly what
 * the old `legacy` flag could not express.
 */
export const STRONGLY_VERIFIED_METHODS: readonly VerificationMethod[] = [
  'otp',
  'future_kyc',
];

export function isStronglyVerified(method: VerificationMethod | null): boolean {
  return method !== null && STRONGLY_VERIFIED_METHODS.includes(method);
}

export interface PayoutDestination {
  readonly id: string;
  readonly provider_user_id: string;
  readonly channel: PayoutChannel;
  readonly country: string;
  readonly normalized_destination: string;
  /** Computed by the database from channel + country + value. Never supplied. */
  readonly destination_fingerprint: string;
  readonly status: PayoutDestinationStatus;
  /** Preference, not permission: which destination a new escrow auto-selects. */
  readonly is_default: boolean;
  readonly verification_method: VerificationMethod | null;
  readonly verified_at: string | null;
  readonly verified_by: string | null;
  readonly verification_id: string | null;
}

/**
 * The frozen record written onto an escrow at FUNDING.
 *
 * Every field is here to answer a question without joining anything that might
 * since have changed or been archived — see migration 106 for the field-by-
 * field justification. `snapshot_version` exists so a reader years from now
 * knows how to interpret the shape.
 */
export interface PayoutDestinationSnapshot {
  readonly snapshot_version: 2;
  readonly destination_id: string;
  /**
   * The field that makes this document outlive the database. `destination_id`
   * is a row pointer — it resolves only while that row exists, in that table,
   * with that id. The fingerprint is derived from the instrument itself, so it
   * still identifies the account after an archive, a re-key or a migration to a
   * successor system.
   */
  readonly destination_fingerprint: string;
  readonly provider_user_id: string;
  readonly channel: PayoutChannel;
  readonly country: string;
  readonly normalized_destination: string;
  /**
   * The status AT CAPTURE — evidence it was usable when we committed, not a
   * claim about now. Named so nobody mistakes a frozen value for a live one.
   */
  readonly status_at_capture: PayoutDestinationStatus;
  readonly verification_method: VerificationMethod | null;
  readonly verified_at: string | null;
  readonly verification_id: string | null;
  /**
   * The `payout_snapshot_captured` audit event, written in the same transaction
   * as this snapshot. Strictly derivable by querying the audit log for this
   * escrow, so it is a convenience pointer rather than load-bearing — but
   * self-containment is the goal, and a reader holding only this JSON should
   * reach the forensic trail in one hop without knowing how we index it.
   */
  readonly audit_event_id: string | null;
  readonly captured_at: string;
}

/** Which route answered. Emitted on every payout so Phase 4 has a real gate. */
export type PayoutSource = 'escrow_snapshot' | 'current_destination' | 'none';

/**
 * Discriminated on a STRING, deliberately.
 *
 * The obvious shape here is `{ ok: true } | { ok: false }`, and it does not work
 * in this codebase: `tsconfig.json` sets `strictNullChecks: false`, under which
 * TypeScript will not narrow a union on a boolean-literal discriminant — every
 * `if (out.ok)` leaves the full union, and `out.reason` fails to compile even
 * inside the guard. A string discriminant narrows correctly either way.
 *
 * It also reads better at the call site: `if (resolved.kind === 'refused')`
 * says what happened, where `if (!resolved.ok)` only says it did not work.
 */
export type ResolveOutcome =
  | {
      readonly kind: 'paid';
      readonly destinationId: string;
      readonly msisdn: string;
      readonly source: PayoutSource;
      readonly verified: boolean;
    }
  | {
      readonly kind: 'refused';
      readonly reason: ResolveFailure;
      readonly source: PayoutSource;
    };

export type ResolveFailure =
  /** Nothing on file at all — the provider has never added a payout number. */
  | 'no_destination'
  /** On file but never proven, and unverified payouts are no longer accepted. */
  | 'not_verified'
  /** The frozen destination has since been retired (it is still paid — see notes). */
  | 'retired'
  /** Legacy fallback was needed but the transition has ended. */
  | 'legacy_fallback_disabled';

export interface ResolveInput {
  /** Frozen at escrow creation. Its presence ends the decision. */
  readonly snapshot: PayoutDestinationSnapshot | null;
  /** The provider's current payable destination, if any. Transitional only. */
  readonly current: PayoutDestination | null;
  /** Phase 2/3 = true. Phase 4 flips this to false and the fallback dies. */
  readonly allowLegacyFallback: boolean;
  /** Phase 5 = true: refuse anything that is not OTP-verified. */
  readonly requireVerified: boolean;
}

/** A destination that money may actually be sent to. */
export function isPayable(status: PayoutDestinationStatus): boolean {
  return status === 'active';
}

export function resolvePayoutDestination(input: ResolveInput): ResolveOutcome {
  const { snapshot, current, allowLegacyFallback, requireVerified } = input;

  // ---- Rule 1: the frozen destination wins, unconditionally. ----
  //
  // NOTE ON RETIRED SNAPSHOTS, WHICH LOOKS WRONG AND IS NOT:
  // A provider may retire a destination after the escrow was created. We still
  // pay the snapshot. The money was earned under terms that named this
  // destination, and the provider proved control of it at that time. Silently
  // re-routing to a newly added number is precisely the takeover this whole
  // design exists to prevent — an attacker who adds and verifies a destination
  // must not thereby capture payouts for work already completed.
  //
  // Retiring a number therefore affects FUTURE jobs. That is the contract, and
  // it is stated in `docs/payout-destination-architecture.md`.
  if (snapshot) {
    // Phase 5 asks for PROOF, not merely for trust. A destination admitted by
    // `migration` or asserted by an `admin` has a verified_at — it was trusted
    // — but nobody demonstrated control of it, and that is the distinction the
    // old boolean could not draw.
    if (requireVerified && !isStronglyVerified(snapshot.verification_method)) {
      return { kind: 'refused', reason: 'not_verified', source: 'escrow_snapshot' };
    }
    return {
      kind: 'paid',
      destinationId: snapshot.destination_id,
      msisdn: snapshot.normalized_destination,
      source: 'escrow_snapshot',
      verified: isStronglyVerified(snapshot.verification_method),
    };
  }

  // ---- Rules 2 and 3: transitional fallback for pre-migration escrows. ----
  if (!allowLegacyFallback) {
    return { kind: 'refused', reason: 'legacy_fallback_disabled', source: 'none' };
  }
  if (!current) {
    return { kind: 'refused', reason: 'no_destination', source: 'none' };
  }
  if (!isPayable(current.status)) {
    return { kind: 'refused', reason: 'retired', source: 'current_destination' };
  }
  if (requireVerified && !isStronglyVerified(current.verification_method)) {
    return { kind: 'refused', reason: 'not_verified', source: 'current_destination' };
  }

  return {
    kind: 'paid',
    destinationId: current.id,
    msisdn: current.normalized_destination,
    source: 'current_destination',
    verified: isStronglyVerified(current.verification_method),
  };
}

/**
 * Build the frozen copy written onto an escrow at FUNDING.
 *
 * `auditEventId` is generated by the caller BEFORE the audit event is inserted,
 * so the snapshot and the event can be written in one transaction with neither
 * pointing at something that does not yet exist.
 */
export function snapshotOf(
  destination: PayoutDestination,
  capturedAt: Date,
  auditEventId: string | null = null,
): PayoutDestinationSnapshot {
  return {
    snapshot_version: 2,
    destination_id: destination.id,
    destination_fingerprint: destination.destination_fingerprint,
    provider_user_id: destination.provider_user_id,
    channel: destination.channel,
    country: destination.country,
    normalized_destination: destination.normalized_destination,
    status_at_capture: destination.status,
    verification_method: destination.verification_method,
    verified_at: destination.verified_at,
    verification_id: destination.verification_id,
    audit_event_id: auditEventId,
    captured_at: capturedAt.toISOString(),
  };
}

/** Copy a failure into the sentence a provider should read. */
export function explainFailure(reason: ResolveFailure): string {
  switch (reason) {
    case 'no_destination':
      return 'The provider has not added an M-Pesa payout number yet.';
    case 'not_verified':
      return 'The provider has not confirmed their M-Pesa payout number yet.';
    case 'retired':
      return 'The provider’s payout number is no longer active.';
    case 'legacy_fallback_disabled':
      return 'This payment predates verified payouts and needs manual settlement.';
  }
}
