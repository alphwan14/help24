import { MpesaService } from './mpesa.service';
import { EVENT_TYPES } from '../events/event.types';

/**
 * Payout settlement state-machine tests (Phase 2).
 *
 * Covers the single idempotent terminal writer (settleByTransaction) reached via
 * handleB2cCallback and reconcilePayout:
 *   1. successful callback releases tx + escrow and emits escrow.released once
 *   2. failed callback reverts to paid/locked and records a failure_reason
 *   3. duplicate callback is a safe no-op (no double-release, no double-notify)
 *   4. dev reconcile settles a stranded payout_pending payout end-to-end
 *   5. split-brain (tx released, escrow stale) is repaired without re-notifying
 *   6. prod reconcile only DISPATCHES a Daraja query — it never settles inline
 */

type EscrowRow = { status: string; released_at: string | null } | null;

function buildService(opts: { dev?: boolean; escrowRow?: EscrowRow; post?: any } = {}) {
  // devForceSuccess is read in the constructor, so set env before instantiation.
  if (opts.dev) process.env.MPESA_DEV_FORCE_SUCCESS = 'true';
  else delete process.env.MPESA_DEV_FORCE_SUCCESS;
  // jest runs with NODE_ENV=test, so the production hard-block never trips here.

  const escrowUpdates: any[] = [];
  const post = opts.post ?? { title: 'Laptop Repairs', author_user_id: 'buyer1', selected_provider_id: 'prov1' };

  const supabase = {
    client: {
      from(table: string) {
        if (table === 'escrow') {
          return {
            select: () => ({
              eq: () => ({ maybeSingle: () => Promise.resolve({ data: opts.escrowRow ?? null, error: null }) }),
            }),
            update: (payload: any) => {
              escrowUpdates.push(payload);
              const eqResult: any = Promise.resolve({ error: null });
              eqResult.neq = () => Promise.resolve({ error: null });
              return { eq: () => eqResult };
            },
          };
        }
        if (table === 'posts') {
          return { select: () => ({ eq: () => ({ single: () => Promise.resolve({ data: post, error: null }) }) }) };
        }
        return {
          select: () => ({
            eq: () => ({
              single: () => Promise.resolve({ data: null, error: null }),
              maybeSingle: () => Promise.resolve({ data: null, error: null }),
            }),
          }),
        };
      },
    },
  };

  const transactions = {
    findByConversationId: jest.fn(),
    findByOriginatorConversationId: jest.fn(),
    findLatestByPostId: jest.fn(),
    update: jest.fn().mockResolvedValue(undefined),
  };
  const daraja = {
    transactionStatusQuery: jest
      .fn()
      .mockResolvedValue({ conversationId: 'c', originatorConversationId: 'o', responseCode: '0' }),
  };
  const events = { emit: jest.fn() };
  const notifications = {};

  // constructor: (daraja, transactions, supabase, notifications, events)
  const service = new MpesaService(
    daraja as any,
    transactions as any,
    supabase as any,
    notifications as any,
    events as any,
  );
  return { service, transactions, daraja, events, escrowUpdates };
}

const emittedTypes = (events: { emit: jest.Mock }) => events.emit.mock.calls.map((c) => c[0].type);

describe('B2C payout settlement', () => {
  afterEach(() => delete process.env.MPESA_DEV_FORCE_SUCCESS);

  it('1. successful callback releases both records and emits escrow.released once', async () => {
    const { service, transactions, events, escrowUpdates } = buildService();
    transactions.findByConversationId.mockResolvedValue({ id: 'tx1', status: 'payout_pending', post_id: 'p1', amount: 1000 });

    await service.handleB2cCallback({ Result: { ResultCode: 0, ResultDesc: 'ok', ConversationID: 'c1' } });

    expect(transactions.update).toHaveBeenCalledWith('tx1', { status: 'released' });
    expect(escrowUpdates).toHaveLength(1);
    expect(escrowUpdates[0]).toMatchObject({ status: 'released' });
    expect(escrowUpdates[0].released_at).toBeTruthy();
    expect(emittedTypes(events)).toContain(EVENT_TYPES.ESCROW_RELEASED);
    expect(emittedTypes(events).filter((t) => t === EVENT_TYPES.ESCROW_RELEASED)).toHaveLength(1);
  });

  it('2. failed callback reverts to paid/locked and records a failure_reason', async () => {
    const { service, transactions, events, escrowUpdates } = buildService();
    transactions.findByConversationId.mockResolvedValue({ id: 'tx1', status: 'payout_pending', post_id: 'p1' });

    await service.handleB2cCallback({ Result: { ResultCode: 2001, ResultDesc: 'Insufficient funds', ConversationID: 'c1' } });

    expect(transactions.update).toHaveBeenCalledWith(
      'tx1',
      expect.objectContaining({ status: 'paid', failure_reason: 'Insufficient funds', conversation_id: null }),
    );
    expect(escrowUpdates[0]).toMatchObject({ status: 'locked', provider_id: null });
    expect(emittedTypes(events)).not.toContain(EVENT_TYPES.ESCROW_RELEASED);
  });

  it('3. duplicate callback on an already-released tx is a safe no-op', async () => {
    const { service, transactions, events, escrowUpdates } = buildService({ escrowRow: { status: 'released', released_at: 't' } });
    transactions.findByConversationId.mockResolvedValue({ id: 'tx1', status: 'released', post_id: 'p1' });

    await service.handleB2cCallback({ Result: { ResultCode: 0, ResultDesc: 'ok', ConversationID: 'c1' } });

    expect(transactions.update).not.toHaveBeenCalled();
    expect(escrowUpdates).toHaveLength(0);
    expect(emittedTypes(events)).not.toContain(EVENT_TYPES.ESCROW_RELEASED);
  });

  it('4. dev reconcile settles a stranded payout_pending payout', async () => {
    const { service, transactions, events, daraja } = buildService({ dev: true });
    transactions.findLatestByPostId.mockResolvedValue({ id: 'tx1', status: 'payout_pending', post_id: 'p1', conversation_id: 'AG_x' });

    const res = await service.reconcilePayout('p1', 'admin@help24');

    expect(res.action).toBe('released');
    expect(transactions.update).toHaveBeenCalledWith('tx1', { status: 'released' });
    expect(emittedTypes(events)).toContain(EVENT_TYPES.ESCROW_RELEASED);
    expect(daraja.transactionStatusQuery).not.toHaveBeenCalled(); // dev never calls Daraja
  });

  it('5. split-brain (tx released, escrow stale) is repaired without re-notifying', async () => {
    const { service, transactions, events, daraja, escrowUpdates } = buildService({
      escrowRow: { status: 'payout_pending', released_at: null },
    });
    transactions.findLatestByPostId.mockResolvedValue({ id: 'tx1', status: 'released', post_id: 'p1' });

    const res = await service.reconcilePayout('p1', 'admin@help24');

    expect(res.action).toBe('repaired');
    expect(escrowUpdates[0]).toMatchObject({ status: 'released' });
    expect(transactions.update).not.toHaveBeenCalled(); // tx already terminal
    expect(emittedTypes(events)).not.toContain(EVENT_TYPES.ESCROW_RELEASED); // no double-notify
    expect(daraja.transactionStatusQuery).not.toHaveBeenCalled();
  });

  it('6. prod reconcile dispatches a Daraja status query and does NOT settle inline', async () => {
    const { service, transactions, daraja } = buildService();
    transactions.findLatestByPostId.mockResolvedValue({
      id: 'tx1',
      status: 'payout_pending',
      post_id: 'p1',
      conversation_id: 'AG_x',
      originator_conversation_id: 'orig_x',
    });

    const res = await service.reconcilePayout('p1', 'admin@help24');

    expect(res.action).toBe('query_dispatched');
    expect(daraja.transactionStatusQuery).toHaveBeenCalledWith(
      expect.objectContaining({ originatorConversationId: 'orig_x', occasion: 'AG_x' }),
    );
    expect(transactions.update).not.toHaveBeenCalled(); // money only moves on the async confirmed result
  });
});
