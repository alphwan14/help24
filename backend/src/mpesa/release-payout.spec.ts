import { MpesaService } from './mpesa.service';

/**
 * Regression protection for the releasePayout source-status fix (Sprint 1, Phase 1.1).
 *
 * The original query filtered transactions with .eq('status', 'paid'), so a
 * transaction frozen to 'disputed' at dispute creation could never be paid out.
 * The fix selects from a parameterised set of releasable source statuses:
 *   - normal (approve) flow:    ['paid']
 *   - arbitration release flow:  ['paid', 'disputed']  (opts.allowFromDisputed)
 */

type Captured = { method: string; args: any[] };

/** Minimal chainable Supabase query-builder mock that records calls and resolves a terminal row. */
function queryBuilder(terminal: any, capture: Captured[]) {
  const b: any = {};
  for (const m of ['select', 'eq', 'in', 'order', 'limit']) {
    b[m] = (...args: any[]) => {
      capture.push({ method: m, args });
      return b;
    };
  }
  b.single = () => Promise.resolve(terminal);
  // releasePayout reads the escrow's frozen destination with .maybeSingle().
  // A pre-migration escrow legitimately has none, which is what this suite
  // exercises: the terminal row carries no snapshot, so resolution falls
  // through to the profile-number path.
  b.maybeSingle = () => Promise.resolve(terminal);
  b.update = () => ({ eq: () => Promise.resolve({ error: null }) });
  return b;
}

function makeSupabase(txStatus: string, capture: Captured[]) {
  return {
    client: {
      from(table: string) {
        switch (table) {
          case 'posts':
            return queryBuilder({ data: { id: 'p1', title: 'Job', selected_provider_id: 'prov1' }, error: null }, capture);
          case 'transactions':
            return queryBuilder({ data: { id: 'tx1', status: txStatus, amount: 100, post_id: 'p1' }, error: null }, capture);
          case 'users':
            return queryBuilder({ data: { phone_number: '0712345678' }, error: null }, capture);
          default: // escrow
            return queryBuilder({ data: null, error: null }, capture);
        }
      },
    },
  };
}

function buildService(txStatus: string, opts: { claimWins?: boolean; b2c?: () => Promise<unknown> } = {}) {
  const capture: Captured[] = [];
  const daraja = {
    b2cPayout: jest.fn(opts.b2c ?? (() => Promise.resolve({ conversationId: 'c1', originatorConversationId: 'o1' }))),
  };
  const transactions = {
    update: jest.fn().mockResolvedValue(undefined),
    claimStatus: jest.fn().mockResolvedValue(opts.claimWins ?? true),
  };
  const events = { emit: jest.fn() };
  const supa = makeSupabase(txStatus, capture);
  // Payout destinations DISABLED — this suite pins the pre-migration behaviour,
  // i.e. that an escrow with no frozen destination still settles from the
  // provider's profile number. That path must keep working until Phase 4.
  const payoutDestinations = {
    isEnabled: false,
    buildSnapshot: jest.fn().mockResolvedValue(null),
    parseSnapshot: jest.fn().mockReturnValue(null),
    resolveForPayout: jest
      .fn()
      .mockResolvedValue({ kind: 'refused', reason: 'no_destination', source: 'none' }),
  };

  // Audit emission is a no-op stub here: this suite pins settlement behaviour,
  // and emission is verified separately in payout-audit.emission.spec.ts.
  const payoutAudit = {
    emit: jest.fn().mockResolvedValue(null),
    emitOrThrow: jest.fn().mockResolvedValue(null),
  };

  // constructor: (daraja, transactions, supabase, notifications, events, payoutDestinations, payoutAudit)
  const service = new MpesaService(
    daraja as any,
    transactions as any,
    supa as any,
    {} as any,
    events as any,
    payoutDestinations as any,
    payoutAudit as any,
  );
  return { service, capture, daraja, payoutDestinations, payoutAudit, transactions };
}

const statusFilter = (capture: Captured[]) =>
  capture.find((c) => c.method === 'in' && c.args[0] === 'status')?.args[1];

describe('MpesaService.releasePayout source-status selection', () => {
  it('allows releasing a disputed transaction when allowFromDisputed is set, and initiates B2C', async () => {
    const { service, capture, daraja } = buildService('disputed');

    const res = await service.releasePayout({ post_id: 'p1' }, { allowFromDisputed: true });

    expect(statusFilter(capture)).toEqual(['paid', 'disputed']);
    expect(daraja.b2cPayout).toHaveBeenCalledTimes(1); // the disputed tx is actually paid out
    expect(res.transaction_id).toBe('tx1');
  });

  it('restricts the normal (approve) flow to paid transactions only', async () => {
    const { service, capture } = buildService('paid');

    await service.releasePayout({ post_id: 'p1' });

    expect(statusFilter(capture)).toEqual(['paid']);
  });
});

/**
 * The payout claims the payment BEFORE any money moves (auto-approval work,
 * 2026-11-04). A dispute freezes 'paid' → 'disputed'; the payout moves
 * 'paid' → 'payout_pending'. Both are conditional updates, so whichever lands
 * first wins and the other does nothing. Before this, the payout read 'paid',
 * called Daraja, then wrote 'payout_pending' over a freeze that had landed in
 * between — money sent on a disputed job.
 */
describe('MpesaService.releasePayout claims the payment before Daraja', () => {
  it('claims from the exact status it read, then pays, and never rewrites the status itself', async () => {
    const { service, daraja, transactions } = buildService('paid');

    await service.releasePayout({ post_id: 'p1' });

    expect(transactions.claimStatus).toHaveBeenCalledWith('tx1', ['paid'], 'payout_pending');
    expect(transactions.claimStatus.mock.invocationCallOrder[0])
      .toBeLessThan(daraja.b2cPayout.mock.invocationCallOrder[0]);
    // The post-Daraja write records the conversation ids only — no status.
    for (const [, data] of transactions.update.mock.calls) expect(data).not.toHaveProperty('status');
  });

  it('arbitration claims from disputed', async () => {
    const { service, transactions } = buildService('disputed');
    await service.releasePayout({ post_id: 'p1' }, { allowFromDisputed: true });
    expect(transactions.claimStatus).toHaveBeenCalledWith('tx1', ['disputed'], 'payout_pending');
  });

  it('a dispute that froze the payment first wins: nothing is sent, and the refusal is audited', async () => {
    const { service, daraja, payoutAudit } = buildService('paid', { claimWins: false });

    await expect(service.releasePayout({ post_id: 'p1' })).rejects.toThrow(/Nothing was sent/);

    expect(daraja.b2cPayout).not.toHaveBeenCalled();
    expect(payoutAudit.emit).toHaveBeenCalledWith(
      expect.objectContaining({ eventType: 'payout_refused', reason: 'payment_changed' }),
    );
  });

  it('Daraja certainly refused: the payment goes back to where it was, so a retry can pay it', async () => {
    const { B2cNotSentError } = jest.requireActual('./daraja.service');
    const { service, transactions } = buildService('paid', {
      b2c: () => Promise.reject(new B2cNotSentError('M-Pesa refused the payout: Invalid MSISDN')),
    });

    await expect(service.releasePayout({ post_id: 'p1' })).rejects.toThrow(/Invalid MSISDN/);

    expect(transactions.claimStatus).toHaveBeenLastCalledWith(
      'tx1', ['payout_pending'], 'paid', { failure_reason: expect.stringContaining('Invalid MSISDN') },
    );
  });

  it('outcome unknown (timeout): stays payout_pending so the event retry cannot pay twice', async () => {
    const { service, transactions } = buildService('paid', {
      b2c: () => Promise.reject(new Error('[Daraja] B2C payout failed — HTTP no-response: undefined')),
    });

    await expect(service.releasePayout({ post_id: 'p1' })).rejects.toThrow(/no-response/);

    expect(transactions.claimStatus).toHaveBeenCalledTimes(1); // the claim, never a revert
    expect(transactions.update).toHaveBeenCalledWith(
      'tx1', { failure_reason: expect.stringContaining('B2C outcome unknown') },
    );
  });
});
