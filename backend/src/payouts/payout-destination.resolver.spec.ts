import {
  resolvePayoutDestination,
  snapshotOf,
  isPayable,
  isStronglyVerified,
  type PayoutDestination,
  type PayoutDestinationSnapshot,
  type ResolveOutcome,
} from './payout-destination.resolver';

/** Narrow to the paid branch, and fail loudly (not silently) if it refused. */
function assertPaid(
  o: ResolveOutcome,
): asserts o is Extract<ResolveOutcome, { kind: 'paid' }> {
  if (o.kind !== 'paid') {
    throw new Error(`expected a payout, got refusal: ${o.reason}`);
  }
}

/** Narrow to the refusal branch. A test that silently returns proves nothing. */
function assertRefused(
  o: ResolveOutcome,
): asserts o is Extract<ResolveOutcome, { kind: 'refused' }> {
  if (o.kind !== 'refused') {
    throw new Error(`expected a refusal, got payout to ${o.msisdn}`);
  }
}

/**
 * These tests are the specification of where money goes. Each one is a rule
 * somebody could otherwise "simplify" away, so each says WHY it exists.
 */

/** OTP-proven: the provider demonstrated control of this line. */
const VERIFIED: PayoutDestination = {
  id: 'dest-active',
  provider_user_id: 'provider-1',
  channel: 'mpesa',
  country: 'KE',
  normalized_destination: '254711000001',
  destination_fingerprint: 'pdf1:aaa',
  status: 'active',
  is_default: true,
  verification_method: 'otp',
  verified_at: '2026-08-01T00:00:00.000Z',
  verified_by: 'system',
  verification_id: 'ver-1',
};

/**
 * Backfilled from a profile field. ACTIVE — genuinely usable — but nobody ever
 * proved control of it. This is the case `legacy` used to express as a status,
 * and it is now a statement about provenance instead.
 */
const MIGRATED: PayoutDestination = {
  ...VERIFIED,
  id: 'dest-migrated',
  normalized_destination: '254711000002',
  destination_fingerprint: 'pdf1:bbb',
  verification_method: 'migration',
  verified_by: 'migration_107',
  verification_id: null,
};

/** Asserted by an administrator — trusted, but not proven by the provider. */
const ADMIN_SET: PayoutDestination = {
  ...VERIFIED,
  id: 'dest-admin',
  normalized_destination: '254711000004',
  destination_fingerprint: 'pdf1:ddd',
  verification_method: 'admin',
  verified_by: 'admin:u123',
  verification_id: null,
};

const RETIRED: PayoutDestination = {
  ...VERIFIED,
  id: 'dest-retired',
  normalized_destination: '254711000003',
  destination_fingerprint: 'pdf1:ccc',
  status: 'retired',
  is_default: false,
};

const SNAPSHOT: PayoutDestinationSnapshot = {
  snapshot_version: 2,
  destination_fingerprint: 'pdf1:frozen',
  country: 'KE',
  audit_event_id: 'evt-1',
  destination_id: 'dest-frozen',
  provider_user_id: 'provider-1',
  channel: 'mpesa',
  normalized_destination: '254799999999',
  status_at_capture: 'active',
  verification_method: 'otp',
  verified_at: '2026-07-01T00:00:00.000Z',
  verification_id: 'ver-frozen',
  captured_at: '2026-07-01T00:00:00.000Z',
};

const PHASE_3 = { allowLegacyFallback: true, requireVerified: false };
const PHASE_5 = { allowLegacyFallback: false, requireVerified: true };

describe('payout destination resolution', () => {
  describe('the escrow snapshot is the decision', () => {
    it('pays the frozen destination even when the provider has since added another', () => {
      // THE CENTRAL GUARANTEE. If this ever flips, a provider (or someone who
      // took over their account) can redirect money that was already earned.
      const out = resolvePayoutDestination({
        snapshot: SNAPSHOT,
        current: { ...VERIFIED, normalized_destination: '254700000000' },
        ...PHASE_3,
      });
      expect(out.kind).toBe('paid');
      assertPaid(out);
      expect(out.msisdn).toBe('254799999999');
      expect(out.destinationId).toBe('dest-frozen');
      expect(out.source).toBe('escrow_snapshot');
    });

    it('pays the frozen destination even after it has been retired', () => {
      // Retiring a number affects FUTURE jobs. Money already earned was earned
      // under terms naming this destination, and the provider proved control of
      // it then. Re-routing here would be the takeover we are defending against.
      const out = resolvePayoutDestination({
        snapshot: { ...SNAPSHOT, status_at_capture: 'retired' },
        current: VERIFIED,
        ...PHASE_3,
      });
      expect(out.kind).toBe('paid');
      assertPaid(out);
      expect(out.msisdn).toBe('254799999999');
    });

    it('never consults the current destination when a snapshot exists', () => {
      const out = resolvePayoutDestination({
        snapshot: SNAPSHOT,
        current: null, // provider deleted everything — irrelevant
        ...PHASE_3,
      });
      expect(out.kind).toBe('paid');
      assertPaid(out);
      expect(out.source).toBe('escrow_snapshot');
    });
  });

  describe('transitional fallback for escrows created before the snapshot', () => {
    it('pays a verified current destination and reports the legacy source', () => {
      const out = resolvePayoutDestination({ snapshot: null, current: VERIFIED, ...PHASE_3 });
      expect(out.kind).toBe('paid');
      assertPaid(out);
      expect(out.source).toBe('current_destination'); // countable → Phase 4 gate
      expect(out.verified).toBe(true);
    });

    it('pays a migration-provenance destination during the transition', () => {
      // Migrating must never hold an existing provider's money hostage.
      const out = resolvePayoutDestination({ snapshot: null, current: MIGRATED, ...PHASE_3 });
      expect(out.kind).toBe('paid');
      assertPaid(out);
      expect(out.verified).toBe(false);
    });

    it('refuses when the provider has nothing on file', () => {
      const out = resolvePayoutDestination({ snapshot: null, current: null, ...PHASE_3 });
      expect(out.kind).toBe('refused');
      assertRefused(out);
      expect(out.reason).toBe('no_destination');
    });

    it('refuses a retired current destination', () => {
      const out = resolvePayoutDestination({ snapshot: null, current: RETIRED, ...PHASE_3 });
      expect(out.kind).toBe('refused');
      assertRefused(out);
      expect(out.reason).toBe('retired');
    });
  });

  describe('phase 5 — verified only', () => {
    it('refuses a migration-provenance destination — trusted is not proven', () => {
      const out = resolvePayoutDestination({
        snapshot: null,
        current: MIGRATED,
        allowLegacyFallback: true,
        requireVerified: true,
      });
      expect(out.kind).toBe('refused');
      assertRefused(out);
      expect(out.reason).toBe('not_verified');
    });

    it('refuses a migration-provenance SNAPSHOT rather than paying it', () => {
      const out = resolvePayoutDestination({
        snapshot: {
          ...SNAPSHOT,
          verification_method: 'migration',
          verification_id: null,
        },
        current: VERIFIED,
        ...PHASE_5,
      });
      expect(out.kind).toBe('refused');
      assertRefused(out);
      expect(out.reason).toBe('not_verified');
    });

    it('refuses an ADMIN-asserted destination — trusted by someone else, not proven', () => {
      // The distinction the old boolean could not draw: admin has a verified_at
      // and is genuinely usable, but nobody demonstrated control of the line.
      const out = resolvePayoutDestination({
        snapshot: null,
        current: ADMIN_SET,
        allowLegacyFallback: true,
        requireVerified: true,
      });
      expect(out.kind).toBe('refused');
      assertRefused(out);
      expect(out.reason).toBe('not_verified');
    });

    it('refuses to fall back at all once the transition has ended', () => {
      const out = resolvePayoutDestination({ snapshot: null, current: VERIFIED, ...PHASE_5 });
      expect(out.kind).toBe('refused');
      assertRefused(out);
      expect(out.reason).toBe('legacy_fallback_disabled');
    });

    it('still pays a verified snapshot', () => {
      const out = resolvePayoutDestination({ snapshot: SNAPSHOT, current: null, ...PHASE_5 });
      expect(out.kind).toBe('paid');
    });
  });

  describe('payability is lifecycle, not trust level', () => {
    it('treats only active as payable', () => {
      expect(isPayable('active')).toBe(true);
      expect(isPayable('pending')).toBe(false); // proposed, never admitted
      expect(isPayable('retired')).toBe(false);
    });

    it('separates CAN be paid from WAS PROVEN', () => {
      // A migration destination is payable and unproven at the same time. That
      // pairing is the whole reason `legacy` stopped being a status.
      expect(isPayable(MIGRATED.status)).toBe(true);
      expect(isStronglyVerified(MIGRATED.verification_method)).toBe(false);
      expect(isStronglyVerified(VERIFIED.verification_method)).toBe(true);
      expect(isStronglyVerified(ADMIN_SET.verification_method)).toBe(false);
      expect(isStronglyVerified('future_kyc')).toBe(true);
    });
  });

  describe('snapshots are reproducible', () => {
    it('carries the verification identity, not just the number', () => {
      // "Which verification proved this?" must be answerable years later from
      // the settlement record alone.
      const snap = snapshotOf(VERIFIED, new Date('2026-08-07T10:00:00Z'), 'evt-cap');
      expect(snap).toEqual({
        snapshot_version: 2,
        destination_id: 'dest-active',
        destination_fingerprint: 'pdf1:aaa',
        provider_user_id: 'provider-1',
        channel: 'mpesa',
        country: 'KE',
        normalized_destination: '254711000001',
        status_at_capture: 'active',
        verification_method: 'otp',
        verified_at: '2026-08-01T00:00:00.000Z',
        verification_id: 'ver-1',
        audit_event_id: 'evt-cap',
        captured_at: '2026-08-07T10:00:00.000Z',
      });
    });

    it('survives the destination row being archived or re-keyed', () => {
      // The fingerprint is derived from the INSTRUMENT, so it still identifies
      // the account when `destination_id` no longer resolves to anything.
      const snap = snapshotOf(VERIFIED, new Date('2026-08-07T10:00:00Z'));
      expect(snap.destination_fingerprint).toBe(VERIFIED.destination_fingerprint);
      expect(snap.country).toBe('KE'); // digits are only unique within a plan
    });

    it('records HOW a destination was trusted, not merely THAT it was', () => {
      // An auditor in 2030 holding only this document must be able to tell an
      // OTP-proven payment from one made to a number copied out of a profile.
      const snap = snapshotOf(MIGRATED, new Date('2026-08-07T10:00:00Z'));
      expect(snap.verification_method).toBe('migration');
      expect(snap.verification_id).toBeNull();
      expect(snap.status_at_capture).toBe('active');
    });

    it('is self-contained — every audit question answerable without a join', () => {
      const snap = snapshotOf(VERIFIED, new Date('2026-08-07T10:00:00Z'));
      // where did the money go / over what rail / whose / which record
      expect(snap.normalized_destination).toBeTruthy();
      expect(snap.channel).toBeTruthy();
      expect(snap.provider_user_id).toBeTruthy();
      expect(snap.destination_id).toBeTruthy();
      // when trust was established, how, and by which event
      expect(snap.verified_at).toBeTruthy();
      expect(snap.verification_method).toBeTruthy();
      expect(snap.verification_id).toBeTruthy();
      // which instrument, independent of any row that may be archived
      expect(snap.destination_fingerprint).toBeTruthy();
      expect(snap.country).toBeTruthy();
      // when the terms were fixed, and how to read this document
      expect(snap.captured_at).toBeTruthy();
      expect(snap.snapshot_version).toBe(2);
    });

    it('proves trust predates the money — the sharpest audit question', () => {
      const snap = snapshotOf(VERIFIED, new Date('2026-08-07T10:00:00Z'));
      expect(new Date(snap.verified_at!).getTime()).toBeLessThan(
        new Date(snap.captured_at).getTime(),
      );
    });
  });
});
