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

function buildService(txStatus: string) {
  const capture: Captured[] = [];
  const daraja = { b2cPayout: jest.fn().mockResolvedValue({ conversationId: 'c1', originatorConversationId: 'o1' }) };
  const transactions = { update: jest.fn().mockResolvedValue(undefined) };
  const events = { emit: jest.fn() };
  const supa = makeSupabase(txStatus, capture);
  // constructor: (daraja, transactions, supabase, notifications, events)
  const service = new MpesaService(daraja as any, transactions as any, supa as any, {} as any, events as any);
  return { service, capture, daraja };
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
