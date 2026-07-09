import {
  classifyArchiveMoneyState,
  archiveBlockMessage,
  isArchiveBlocked,
  ArchiveMoneyState,
} from './archive-state';

/**
 * Phase A — truthful archive/delete money-state classification.
 *
 * Every branch of the classifier and every user-facing message is pinned here so
 * a copy change or a lost branch is caught. These are pure functions — no I/O.
 */

const input = (over: Partial<Parameters<typeof classifyArchiveMoneyState>[0]>) => ({
  txStatus: null,
  escrowStatus: null,
  failureReason: null,
  activeDispute: false,
  ...over,
});

describe('classifyArchiveMoneyState', () => {
  it('active dispute → disputed (takes precedence over money state)', () => {
    expect(classifyArchiveMoneyState(input({ txStatus: 'paid', escrowStatus: 'locked', activeDispute: true }))).toBe('disputed');
  });

  it('no transaction / no escrow → no_payment', () => {
    expect(classifyArchiveMoneyState(input({}))).toBe('no_payment');
  });

  it('paid + locked, no failure → in_escrow', () => {
    expect(classifyArchiveMoneyState(input({ txStatus: 'paid', escrowStatus: 'locked' }))).toBe('in_escrow');
  });

  it('pending + locked (optimistic escrow during STK) → in_escrow', () => {
    expect(classifyArchiveMoneyState(input({ txStatus: 'pending', escrowStatus: 'locked' }))).toBe('in_escrow');
  });

  it('paid + locked WITH failure_reason → settlement_failed', () => {
    expect(classifyArchiveMoneyState(input({ txStatus: 'paid', escrowStatus: 'locked', failureReason: 'Insufficient funds' }))).toBe('settlement_failed');
  });

  it('payout_pending + payout_pending → payout_processing (the 2b4925ab case)', () => {
    expect(classifyArchiveMoneyState(input({ txStatus: 'payout_pending', escrowStatus: 'payout_pending' }))).toBe('payout_processing');
  });

  it('released + released → released', () => {
    expect(classifyArchiveMoneyState(input({ txStatus: 'released', escrowStatus: 'released' }))).toBe('released');
  });

  it('refunded + refunded → refunded', () => {
    expect(classifyArchiveMoneyState(input({ txStatus: 'refunded', escrowStatus: 'refunded' }))).toBe('refunded');
  });

  it('failed tx, no escrow → no_payment', () => {
    expect(classifyArchiveMoneyState(input({ txStatus: 'failed', escrowStatus: null }))).toBe('no_payment');
  });

  describe('split-brain / inconsistent combinations', () => {
    const cases: Array<[string, string]> = [
      ['released', 'payout_pending'],
      ['released', 'locked'],
      ['payout_pending', 'released'],
      ['paid', 'released'],
      ['payout_pending', 'locked'],
      ['paid', 'payout_pending'],
      ['refunded', 'released'],
      ['released', 'refunded'],
    ];
    it.each(cases)('tx=%s / escrow=%s → inconsistent', (txStatus, escrowStatus) => {
      expect(classifyArchiveMoneyState(input({ txStatus, escrowStatus }))).toBe('inconsistent');
    });
  });
});

describe('archiveBlockMessage — exact copy per state', () => {
  const expected: Record<string, string> = {
    payout_processing: 'Payout has been initiated and is awaiting confirmation.',
    in_escrow: 'Funds are securely held in escrow.',
    settlement_failed: 'Payout attempt failed and needs attention. Support has been notified.',
    disputed: 'This job has an active dispute and cannot be removed until resolution.',
    inconsistent: 'This payment needs review by support.',
  };
  it.each(Object.entries(expected))('%s → %s', (state, copy) => {
    expect(archiveBlockMessage(state as ArchiveMoneyState)).toBe(copy);
  });

  it('never claims settlement for a completed post stuck in payout_pending', () => {
    const msg = archiveBlockMessage('payout_processing');
    expect(msg).not.toMatch(/released|completed|paid|settled/i);
  });
});

describe('isArchiveBlocked', () => {
  it.each(['disputed', 'in_escrow', 'payout_processing', 'settlement_failed', 'inconsistent'])(
    '%s blocks archive',
    (s) => expect(isArchiveBlocked(s as ArchiveMoneyState)).toBe(true),
  );
  it.each(['no_payment', 'released', 'refunded'])(
    '%s permits archive',
    (s) => expect(isArchiveBlocked(s as ArchiveMoneyState)).toBe(false),
  );

  it('payout_pending money can NEVER be archived (enforcement floor)', () => {
    const state = classifyArchiveMoneyState(input({ txStatus: 'payout_pending', escrowStatus: 'payout_pending' }));
    expect(isArchiveBlocked(state)).toBe(true);
  });
});
