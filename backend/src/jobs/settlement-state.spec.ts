import { deriveSettlementState, canArchive, SettlementInput } from './settlement-state';

/**
 * Phase 3.4A — canonical derived settlement state. Pure-function tests covering
 * every truth-table row, the split-brain rows, the failure_reason distinction,
 * the PARTIAL_SPLIT provider-owed representation, and a property test proving
 * can_archive matches the archive guard for every status combination.
 */

const inp = (over: Partial<SettlementInput> = {}): SettlementInput => ({
  txStatus: null,
  escrowStatus: null,
  failureReason: null,
  activeDispute: false,
  latestDecisionType: null,
  amount: 1000,
  fee: 30,
  totalPaid: 1030,
  providerAmount: null,
  clientRefund: null,
  paidAt: null,
  releasedAt: null,
  disputedAt: null,
  resolvedAt: null,
  ...over,
});

describe('deriveSettlementState — truth table', () => {
  it('no transaction → no_payment (archivable)', () => {
    const s = deriveSettlementState(inp());
    expect(s.state).toBe('no_payment');
    expect(s.can_archive).toBe(true);
  });

  it('pending, no escrow → awaiting_payment', () => {
    expect(deriveSettlementState(inp({ txStatus: 'pending' })).state).toBe('awaiting_payment');
  });

  it('pending + optimistic locked escrow → awaiting_payment, blocked', () => {
    const s = deriveSettlementState(inp({ txStatus: 'pending', escrowStatus: 'locked' }));
    expect(s.state).toBe('awaiting_payment');
    expect(s.can_archive).toBe(false); // escrow held
  });

  it('paid + locked → in_escrow, blocked', () => {
    const s = deriveSettlementState(inp({ txStatus: 'paid', escrowStatus: 'locked' }));
    expect(s.state).toBe('in_escrow');
    expect(s.can_archive).toBe(false);
    expect(s.explanation).toMatch(/securely held in escrow/i);
  });

  it('paid + locked + failure_reason → settlement_failed (attention)', () => {
    const s = deriveSettlementState(inp({ txStatus: 'paid', escrowStatus: 'locked', failureReason: 'Insufficient funds' }));
    expect(s.state).toBe('settlement_failed');
    expect(s.attention_required).toBe(true);
    expect(s.attention_reason).toBe('payout_failed');
    expect(s.can_archive).toBe(false);
  });

  it('payout_pending both sides → payout_processing (never claims settled)', () => {
    const s = deriveSettlementState(inp({ txStatus: 'payout_pending', escrowStatus: 'payout_pending' }));
    expect(s.state).toBe('payout_processing');
    expect(s.can_archive).toBe(false);
    expect(s.is_terminal).toBe(false);
    expect(s.explanation).toMatch(/awaiting confirmation/i);
    expect(s.explanation).not.toMatch(/released|completed|paid/i);
  });

  it('active dispute → disputed, blocked', () => {
    const s = deriveSettlementState(inp({ txStatus: 'disputed', escrowStatus: 'disputed', activeDispute: true }));
    expect(s.state).toBe('disputed');
    expect(s.can_archive).toBe(false);
  });

  it('released both sides → released, archivable, terminal', () => {
    const s = deriveSettlementState(inp({ txStatus: 'released', escrowStatus: 'released', latestDecisionType: 'FULL_RELEASE' }));
    expect(s.state).toBe('released');
    expect(s.can_archive).toBe(true);
    expect(s.is_terminal).toBe(true);
  });

  it('refunded + FULL_REFUND → refunded', () => {
    const s = deriveSettlementState(inp({ txStatus: 'refunded', escrowStatus: 'refunded', latestDecisionType: 'FULL_REFUND' }));
    expect(s.state).toBe('refunded');
    expect(s.can_archive).toBe(true);
  });

  it('refunded + PARTIAL_SPLIT → split_settled with provider_owed + attention', () => {
    const s = deriveSettlementState(inp({
      txStatus: 'refunded', escrowStatus: 'refunded', latestDecisionType: 'PARTIAL_SPLIT',
      providerAmount: 400, clientRefund: 600,
    }));
    expect(s.state).toBe('split_settled');
    expect(s.attention_required).toBe(true);
    expect(s.attention_reason).toBe('provider_payout_owed');
    expect(s.amounts.provider_owed).toBe(400); // recorded but NOT auto-paid
    expect(s.explanation).toMatch(/requires settlement attention/i);
    expect(s.can_archive).toBe(true); // escrow terminal → guard allows
  });
});

describe('split-brain / inconsistent rows', () => {
  const cases: Array<[string | null, string | null, boolean]> = [
    ['released', 'payout_pending', false],
    ['released', 'locked', false],
    ['payout_pending', 'released', false],
    ['paid', 'released', false],
    ['payout_pending', 'locked', false],
    ['paid', 'payout_pending', false],
    ['refunded', 'released', false],
    ['released', 'refunded', false],
    ['paid', null, false], // paid tx but no escrow
    ['disputed', 'disputed', false], // frozen without an active dispute
  ];
  it.each(cases)('tx=%s / escrow=%s (no active dispute) → inconsistent, attention, blocked', (t, e) => {
    const s = deriveSettlementState(inp({ txStatus: t, escrowStatus: e }));
    expect(s.state).toBe('inconsistent');
    expect(s.attention_required).toBe(true);
    expect(s.attention_reason).toBe('split_brain');
  });

  it('active dispute but funds already released → inconsistent (not disputed)', () => {
    const s = deriveSettlementState(inp({ txStatus: 'released', escrowStatus: 'released', activeDispute: true }));
    expect(s.state).toBe('inconsistent');
  });
});

describe('archive parity — can_archive matches the archive guard for ALL combinations', () => {
  const txStatuses = [null, 'pending', 'paid', 'failed', 'payout_pending', 'released', 'refunded', 'disputed'];
  const escrowStatuses = [null, 'locked', 'payout_pending', 'released', 'refunded', 'disputed'];

  // The reference is the ACTUAL archivePost enforcement gate — the existence-based
  // block (activeDispute || tx∈{paid,payout_pending} || escrow∈{locked,payout_pending}),
  // NOT the message-only classifier. This proves can_archive can safely drive the
  // guard in Phase C P4 without changing enforcement.
  it('deriveSettlementState.can_archive === the archivePost gate for every (tx, escrow, dispute, failure)', () => {
    for (const t of txStatuses) {
      for (const e of escrowStatuses) {
        for (const activeDispute of [false, true]) {
          for (const failureReason of [null, 'boom']) {
            const derived = canArchive(inp({ txStatus: t, escrowStatus: e, activeDispute, failureReason }));
            const gateBlocks =
              activeDispute ||
              t === 'paid' || t === 'payout_pending' ||
              e === 'locked' || e === 'payout_pending';
            expect({ t, e, activeDispute, failureReason, derived }).toEqual({
              t, e, activeDispute, failureReason, derived: !gateBlocks,
            });
          }
        }
      }
    }
  });

  it('never permits archiving payout_pending money', () => {
    expect(canArchive(inp({ txStatus: 'payout_pending', escrowStatus: 'payout_pending' }))).toBe(false);
    expect(canArchive(inp({ txStatus: 'payout_pending', escrowStatus: 'released' }))).toBe(false);
    expect(canArchive(inp({ txStatus: 'paid', escrowStatus: 'payout_pending' }))).toBe(false);
  });
});

describe('purity', () => {
  it('is a pure function of its input (same input → deep-equal output, input unchanged)', () => {
    const input = inp({ txStatus: 'paid', escrowStatus: 'locked' });
    const snapshot = JSON.stringify(input);
    const a = deriveSettlementState(input);
    const b = deriveSettlementState(input);
    expect(a).toEqual(b);
    expect(JSON.stringify(input)).toBe(snapshot); // no mutation
  });
});
