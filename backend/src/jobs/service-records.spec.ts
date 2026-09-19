import { BadRequestException, ForbiddenException, NotFoundException } from '@nestjs/common';
import { ServiceRecordsService } from './service-records.service';

/**
 * Service Records — receipt issuance, status truthfulness and participant
 * scoping.
 *
 * The cases here are Phase 13's failure matrix: a receipt must never be issued
 * for money that has not moved, must never show a status the canonical state
 * machine does not agree with, and must never hand one party the other's
 * mobile-money reference.
 */

/**
 * Chainable Supabase mock. `rows[table]` is the payload every terminal on that
 * table resolves to; `inserts` records what was written so the idempotency test
 * can assert the second call performed no INSERT at all.
 */
function makeSupabase(rows: Record<string, any>, inserts: Record<string, any[]> = {}) {
  const builder = (table: string): any => {
    const b: any = {};
    for (const m of ['select', 'eq', 'order', 'limit', 'in', 'not', 'range']) b[m] = () => b;
    b.single = () => Promise.resolve({ data: rows[table] ?? null, error: null });
    b.maybeSingle = () => Promise.resolve({ data: rows[table] ?? null, error: null });
    b.insert = (payload: any) => {
      (inserts[table] ??= []).push(payload);
      // Emulate the DB DEFAULTs that allocate the number server-side.
      const issued = {
        receipt_number: 'HLP-2026-000042',
        issued_at: '2026-09-12T10:00:00Z',
        payment_method: 'mpesa',
      };
      rows[table] = issued; // subsequent SELECTs now find it, as in the real DB
      const ib: any = {};
      ib.select = () => ib;
      ib.maybeSingle = () => Promise.resolve({ data: issued, error: null });
      return ib;
    };
    b.then = (resolve: (v: any) => any) => resolve({ data: rows[table] ?? [], error: null });
    return b;
  };
  return { client: { from: builder } };
}

const POST = {
  id: 'p1',
  title: 'Bathroom Plumbing',
  description: 'Fix the leaking sink',
  category: 'Plumbing',
  location: 'Kilimani, Nairobi',
  author_user_id: 'client1',
  selected_provider_id: 'prov1',
  created_at: '2026-09-10T08:00:00Z',
};

const PAID_TX = {
  id: 'tx1',
  status: 'paid',
  amount: 2500,
  fee: 45,
  total_paid: 2545,
  mpesa_receipt: 'SGH7XK2LMN',
  failure_reason: null,
  created_at: '2026-09-11T09:00:00Z',
};

function svc(rows: Record<string, any>, inserts: Record<string, any[]> = {}) {
  return new ServiceRecordsService(makeSupabase(rows, inserts) as any);
}

// ── Participant scoping ──────────────────────────────────────────────────────

describe('getReceipt participant scoping', () => {
  it('refuses a stranger', async () => {
    await expect(svc({ posts: POST }).getReceipt('p1', 'stranger')).rejects.toBeInstanceOf(
      ForbiddenException,
    );
  });

  it('404s a missing post', async () => {
    await expect(svc({ posts: null }).getReceipt('nope', 'client1')).rejects.toBeInstanceOf(
      NotFoundException,
    );
  });

  it('requires a user_id', async () => {
    await expect(svc({ posts: POST }).getReceipt('p1', '')).rejects.toBeInstanceOf(BadRequestException);
  });
});

// ── Phase 13: a receipt is never issued for money that has not moved ─────────

describe('receipt availability gating', () => {
  it('is unavailable when no payment exists', async () => {
    const r: any = await svc({ posts: POST, transactions: null }).getReceipt('p1', 'client1');
    expect(r.available).toBe(false);
    expect(r.reason).toBe('no_payment');
  });

  it('is unavailable while the STK payment is still pending', async () => {
    const r: any = await svc({
      posts: POST,
      transactions: { ...PAID_TX, status: 'pending', mpesa_receipt: null },
    }).getReceipt('p1', 'client1');
    expect(r.available).toBe(false);
    expect(r.reason).toBe('payment_pending');
    expect(r.message).toMatch(/still being confirmed/i);
  });

  it('is unavailable for a failed payment, and surfaces the real failure reason', async () => {
    const r: any = await svc({
      posts: POST,
      transactions: {
        ...PAID_TX,
        status: 'failed',
        mpesa_receipt: null,
        failure_reason: 'Request cancelled by user',
      },
    }).getReceipt('p1', 'client1');
    expect(r.available).toBe(false);
    expect(r.reason).toBe('payment_failed');
    expect(r.message).toBe('Request cancelled by user');
  });

  it('never fabricates a transaction reference when one is absent', async () => {
    const r: any = await svc({
      posts: POST,
      transactions: { ...PAID_TX, mpesa_receipt: null },
      escrow: { status: 'locked', released_at: null },
    }).getReceipt('p1', 'client1');
    expect(r.available).toBe(true);
    expect(r.provider_reference).toBeNull();
    expect(r.receipt_number).toMatch(/^HLP-\d{4}-\d{6}$/);
  });
});

// ── Status mirrors the canonical settlement state, never a second opinion ────

describe('receipt status derives from the canonical settlement state', () => {
  const cases: Array<[string, any, any, string]> = [
    ['ESCROWED while funds are held', PAID_TX, { status: 'locked', released_at: null }, 'ESCROWED'],
    [
      'ESCROWED while the payout is in flight',
      { ...PAID_TX, status: 'payout_pending' },
      { status: 'payout_pending', released_at: null },
      'ESCROWED',
    ],
    [
      'RELEASED once the provider is paid',
      { ...PAID_TX, status: 'released' },
      { status: 'released', released_at: '2026-09-13T12:00:00Z' },
      'RELEASED',
    ],
    [
      'REFUNDED on a full refund',
      { ...PAID_TX, status: 'refunded' },
      { status: 'refunded', released_at: null },
      'REFUNDED',
    ],
  ];

  for (const [name, tx, escrow, expected] of cases) {
    it(name, async () => {
      const r: any = await svc({ posts: POST, transactions: tx, escrow }).getReceipt('p1', 'client1');
      expect(r.status).toBe(expected);
      expect(r.available).toBe(true);
    });
  }

  it('DISPUTED while a dispute is open, and freezes no money into a clean status', async () => {
    const r: any = await svc({
      posts: POST,
      transactions: { ...PAID_TX, status: 'disputed' },
      escrow: { status: 'disputed', released_at: null },
      disputes: { id: 'd1', status: 'open', created_at: 'x', resolved_at: null },
      dispute_decisions: [],
    }).getReceipt('p1', 'client1');
    expect(r.status).toBe('DISPUTED');
  });

  it('PARTIALLY_REFUNDED after a resolved PARTIAL_SPLIT, and reports the refunded amount', async () => {
    const r: any = await svc({
      posts: POST,
      transactions: { ...PAID_TX, status: 'refunded' },
      escrow: { status: 'refunded', released_at: null },
      disputes: {
        id: 'd1',
        status: 'resolved',
        provider_amount: 1500,
        buyer_refund: 1000,
        created_at: 'x',
        resolved_at: 'y',
      },
      dispute_decisions: [
        { decision_type: 'PARTIAL_SPLIT', provider_amount: 1500, client_refund_amount: 1000, created_at: 'z' },
      ],
    }).getReceipt('p1', 'client1');
    expect(r.status).toBe('PARTIALLY_REFUNDED');
    expect(r.refunded_amount).toBe(1000);
  });

  it('says UNDER_REVIEW rather than inventing a clean status for a split-brain record', async () => {
    // tx paid but no escrow row — deriveSettlementState calls this 'inconsistent'.
    const r: any = await svc({ posts: POST, transactions: PAID_TX, escrow: null }).getReceipt(
      'p1',
      'client1',
    );
    expect(r.status).toBe('UNDER_REVIEW');
  });
});

// ── Phase 16: the payer's mobile-money reference is not shared ───────────────

describe('provider reference privacy', () => {
  const rows = () => ({ posts: POST, transactions: PAID_TX, escrow: { status: 'locked', released_at: null } });

  it('shows the M-Pesa reference to the client who paid', async () => {
    const r: any = await svc(rows()).getReceipt('p1', 'client1');
    expect(r.provider_reference).toBe('SGH7XK2LMN');
    expect(r.provider_reference_visible).toBe(true);
    expect(r.viewer_role).toBe('client');
  });

  it("withholds it from the provider, and says so rather than implying it is missing", async () => {
    const r: any = await svc(rows()).getReceipt('p1', 'prov1');
    expect(r.provider_reference).toBeNull();
    expect(r.provider_reference_visible).toBe(false);
    expect(r.viewer_role).toBe('provider');
    // The provider still gets a complete work record.
    expect(r.receipt_number).toMatch(/^HLP-/);
    expect(r.amount).toBe(2500);
  });
});

// ── Phase 11 / TEST 16: repeated calls do not mint a second receipt ──────────

describe('receipt issuance is idempotent', () => {
  it('issues once and reuses the number on every later call', async () => {
    const inserts: Record<string, any[]> = {};
    const rows: Record<string, any> = {
      posts: POST,
      transactions: PAID_TX,
      escrow: { status: 'locked', released_at: null },
      payment_receipts: null, // none issued yet
    };
    const s = svc(rows, inserts);

    const first: any = await s.getReceipt('p1', 'client1');
    const second: any = await s.getReceipt('p1', 'client1');
    const third: any = await s.getReceipt('p1', 'prov1');

    expect(first.receipt_number).toBe(second.receipt_number);
    expect(third.receipt_number).toBe(first.receipt_number);
    // Exactly ONE write, on the first call only.
    expect(inserts.payment_receipts).toHaveLength(1);
  });

  it('performs no write at all when a receipt already exists', async () => {
    const inserts: Record<string, any[]> = {};
    const s = svc(
      {
        posts: POST,
        transactions: PAID_TX,
        escrow: { status: 'locked', released_at: null },
        payment_receipts: {
          receipt_number: 'HLP-2026-000007',
          issued_at: '2026-09-11T10:00:00Z',
          payment_method: 'mpesa',
        },
      },
      inserts,
    );
    const r: any = await s.getReceipt('p1', 'client1');
    expect(r.receipt_number).toBe('HLP-2026-000007');
    expect(inserts.payment_receipts).toBeUndefined();
  });
});

// ── Money shape ──────────────────────────────────────────────────────────────

describe('receipt money is reported in whole KES, as stored', () => {
  it('reports amount, platform fee and total exactly as the transaction holds them', async () => {
    const r: any = await svc({
      posts: POST,
      transactions: PAID_TX,
      escrow: { status: 'locked', released_at: null },
    }).getReceipt('p1', 'client1');
    expect(r.amount).toBe(2500);
    expect(r.platform_fee).toBe(45);
    expect(r.total_paid).toBe(2545);
    expect(r.currency).toBe('KES');
    // The Help24 transaction id is its own field, distinct from the M-Pesa ref.
    expect(r.transaction_id).toBe('tx1');
    expect(r.transaction_id).not.toBe(r.provider_reference);
  });
});

// ── History listing ──────────────────────────────────────────────────────────

describe('listHistory validation', () => {
  it('requires a user_id', async () => {
    await expect(svc({}).listHistory('', 'client')).rejects.toBeInstanceOf(BadRequestException);
  });

  it('rejects a role that is neither client nor provider', async () => {
    await expect(svc({}).listHistory('u1', 'admin' as any)).rejects.toBeInstanceOf(BadRequestException);
  });

  it('returns an empty result rather than throwing when the user has no records', async () => {
    const res = await svc({ posts: [] }).listHistory('u1', 'client');
    expect(res.records).toEqual([]);
    expect(res.total_completed).toBe(0);
    expect(res.completed_value).toBe(0);
    expect(res.has_more).toBe(false);
  });
});

describe('completed work is counted from the completion, not from settlement', () => {
  /**
   * Reproduces the exact shape production is in today: an approved completion
   * whose payout is still stuck in payout_pending. The provider HAS finished
   * this job. Counting from settlement_state would report zero completed jobs
   * to a provider who has completed one, because no transaction in production
   * has ever reached 'released'.
   */
  const stuckPayoutButApproved = {
    posts: [
      {
        id: 'p1',
        title: 'Laptop Repairs',
        category: 'Electronics',
        location: 'Nairobi',
        price: 500,
        status: 'completed',
        author_user_id: 'client1',
        selected_provider_id: 'prov1',
        created_at: '2026-06-20T08:00:00Z',
        archived_at: null,
      },
    ],
    transactions: [
      {
        id: 'tx1',
        post_id: 'p1',
        status: 'payout_pending',
        amount: 500,
        fee: 20,
        total_paid: 520,
        failure_reason: null,
        created_at: '2026-06-21T08:00:00Z',
      },
    ],
    escrow: [{ transaction_id: 'tx1', status: 'payout_pending', released_at: null }],
    job_completions: [
      { post_id: 'p1', status: 'approved', reviewed_at: '2026-06-22T09:03:50Z', created_at: '2026-06-22T08:00:00Z' },
    ],
    disputes: [],
    dispute_decisions: [],
    users: [{ id: 'client1', name: 'Alphonse Lincoln' }],
    payment_receipts: [],
  };

  it('counts an approved completion whose payout is still in flight', async () => {
    const res = await svc({ ...stuckPayoutButApproved }).listHistory('prov1', 'provider');
    expect(res.records).toHaveLength(1);
    const r = res.records[0];

    // The money is honestly reported as NOT settled...
    expect(r.settlement_state).toBe('payout_processing');
    expect(r.settled_at).toBeNull();
    // ...while the work is honestly reported as DONE.
    expect(r.completed_at).toBe('2026-06-22T09:03:50Z');
    expect(res.total_completed).toBe(1);
    expect(res.completed_value).toBe(500);

    // And the counterparty is named from the other side of the deal.
    expect(r.viewer_role).toBe('provider');
    expect(r.counterparty.name).toBe('Alphonse Lincoln');
  });

  it('does not count a disputed completion as completed work', async () => {
    const res = await svc({
      ...stuckPayoutButApproved,
      job_completions: [
        { post_id: 'p1', status: 'disputed', reviewed_at: '2026-06-22T09:03:50Z', created_at: '2026-06-22T08:00:00Z' },
      ],
    }).listHistory('prov1', 'provider');
    expect(res.records[0].completed_at).toBeNull();
    expect(res.total_completed).toBe(0);
    expect(res.completed_value).toBe(0);
  });

  it('falls back to the agreed post price when no payment exists yet', async () => {
    const res = await svc({
      ...stuckPayoutButApproved,
      transactions: [],
      escrow: [],
      job_completions: [],
    }).listHistory('prov1', 'provider');
    const r = res.records[0];
    expect(r.settlement_state).toBe('no_payment');
    expect(r.amount).toBe(500); // the agreed price, not an invented figure
    expect(r.total_paid).toBeNull(); // nothing was paid, and it does not pretend otherwise
    expect(r.receipt_available).toBe(false);
  });
});
