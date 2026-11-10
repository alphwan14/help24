import { BadRequestException, ConflictException, ForbiddenException } from '@nestjs/common';
import { MaterialsAdvanceService } from './materials-advance.service';
import { B2cNotSentError } from './daraja.service';

/**
 * Materials Advance (migration 139): the money moves, against a stateful fake
 * of the table that honours compare-and-set (`update ... eq('status', x)`
 * only applies while the row still has status x). That is what makes the
 * races below real: release vs approval vs dispute.
 *
 * Owner decisions 2026-11-10: the customer releases it, verified providers
 * only, KES 10,000+, 40%; a failed job refunds the held part plus the fee.
 */

type Op = { method: string; args: unknown[] };
type Adv = Record<string, unknown>;

const BASE: Adv = {
  id: 'adv1',
  transaction_id: 'tx1',
  post_id: 'p1',
  client_user_id: 'client1',
  provider_user_id: 'prov1',
  amount: 4_000,
  status: 'held',
  conversation_id: null,
  originator_conversation_id: null,
  failure_reason: null,
  release_requested_at: null,
  paid_out_at: null,
};

function world(init: {
  advance?: Partial<Adv> | null;
  txStatus?: string;
  disputes?: string[];
  verified?: boolean;
  price?: number;
  advanceReadError?: { code?: string; message: string };
} = {}) {
  const state = {
    advance: init.advance === null ? null : ({ ...BASE, ...(init.advance ?? {}) } as Adv | null),
    txStatus: init.txStatus ?? 'paid',
    disputes: init.disputes ?? [],
  };
  const matches = (row: Adv, ops: Op[]) =>
    ops.filter((o) => o.method === 'eq').every((o) => row[o.args[0] as string] === o.args[1]);

  const reply = (table: string, ops: Op[]): { data: unknown; error: unknown } => {
    const update = ops.find((o) => o.method === 'update')?.args[0] as Adv | undefined;
    const insert = ops.find((o) => o.method === 'insert')?.args[0] as Adv | undefined;
    if (table === 'materials_advances') {
      if (insert) {
        state.advance = { ...BASE, ...insert, id: 'adv-new' };
        return { data: null, error: null };
      }
      if (update) {
        if (state.advance && matches(state.advance, ops)) {
          Object.assign(state.advance, update);
          return { data: [{ id: state.advance.id }], error: null };
        }
        return { data: [], error: null };
      }
      if (init.advanceReadError) return { data: null, error: init.advanceReadError };
      return { data: state.advance && matches(state.advance, ops) ? { ...state.advance } : null, error: null };
    }
    if (table === 'transactions') return { data: { id: 'tx1', status: state.txStatus }, error: null };
    if (table === 'posts') {
      return {
        data: { id: 'p1', title: 'Roof repair', price: init.price ?? 10_000, author_user_id: 'client1', selected_provider_id: 'prov1' },
        error: null,
      };
    }
    if (table === 'disputes') return { data: state.disputes.map((status) => ({ status })), error: null };
    if (table === 'escrow') return { data: { payout_destination_snapshot: null }, error: null };
    if (table === 'users') return { data: { phone_number: '0712345678' }, error: null };
    return { data: null, error: null };
  };

  const from = (table: string) => {
    const ops: Op[] = [];
    const answer = () => Promise.resolve(reply(table, ops));
    const chain: any = new Proxy(
      {},
      {
        get(_t, prop: string) {
          if (prop === 'then') return (ok: any, bad: any) => answer().then(ok, bad);
          if (prop === 'maybeSingle' || prop === 'single') return () => answer();
          return (...args: unknown[]) => {
            ops.push({ method: prop, args });
            return chain;
          };
        },
      },
    );
    return chain;
  };
  const rpc = jest.fn().mockResolvedValue({ data: [{ id_verified: init.verified ?? true }], error: null });

  const daraja = {
    b2cPayout: jest.fn().mockResolvedValue({ conversationId: 'AG_ADV_1', originatorConversationId: 'OR_ADV_1' }),
  };
  const payoutDestinations = {
    isEnabled: false,
    parseSnapshot: () => null,
    resolveForPayout: jest.fn().mockResolvedValue({ kind: 'unavailable', reason: 'feature_disabled', source: 'none' }),
  };
  const payoutAudit = { emit: jest.fn().mockResolvedValue(null), emitOrThrow: jest.fn().mockResolvedValue(null) };
  const notifications = { send: jest.fn().mockResolvedValue(undefined), sendMany: jest.fn().mockResolvedValue(undefined) };
  const events = { emit: jest.fn() };
  const service = new MaterialsAdvanceService(
    { client: { from, rpc } } as any,
    daraja as any,
    payoutDestinations as any,
    payoutAudit as any,
    notifications as any,
    events as any,
  );
  return { service, state, daraja, payoutAudit, notifications, events };
}

beforeEach(() => {
  process.env.MATERIALS_ADVANCE_ENABLED = 'true';
});
afterAll(() => {
  delete process.env.MATERIALS_ADVANCE_ENABLED;
});

describe('quote (the payment screen)', () => {
  it('offers 40% on a KES 10,000 job with a verified provider, at the normal fee', async () => {
    const { service } = world();
    await expect(service.quote('p1', 'client1')).resolves.toMatchObject({
      available: true, reason: null, job_amount: 10_000, advance_amount: 4_000, fee: 500, total: 10_500,
    });
  });

  it('says why it is not offered', async () => {
    await expect(world({ verified: false }).service.quote('p1', 'client1')).resolves.toMatchObject({
      available: false, reason: 'provider_not_verified', advance_amount: 0,
    });
    await expect(world({ price: 9_999 }).service.quote('p1', 'client1')).resolves.toMatchObject({
      available: false, reason: 'too_small',
    });
    process.env.MATERIALS_ADVANCE_ENABLED = 'false';
    await expect(world().service.quote('p1', 'client1')).resolves.toMatchObject({ available: false, reason: 'disabled' });
  });

  it('is only for the customer who posted the job', async () => {
    await expect(world().service.quote('p1', 'prov1')).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('checkout refuses an advance the job does not qualify for', async () => {
    await expect(world({ verified: false }).service.assertEligible(10_000, 'prov1')).rejects.toBeInstanceOf(BadRequestException);
    await expect(world().service.assertEligible(9_000, 'prov1')).rejects.toBeInstanceOf(BadRequestException);
    await expect(world().service.assertEligible(12_000, 'prov1')).resolves.toBe(4_800);
  });
});

describe('release (the customer taps "Send materials money")', () => {
  it('claims the advance, then pays 40% to the provider and records the M-Pesa ids', async () => {
    const { service, state, daraja, payoutAudit } = world();
    const r = await service.release('p1', 'client1');
    expect(r.status).toBe('sending');
    expect(daraja.b2cPayout).toHaveBeenCalledWith({ phone: '254712345678', amount: 4_000, jobId: 'p1' });
    expect(state.advance).toMatchObject({ status: 'sending', conversation_id: 'AG_ADV_1', originator_conversation_id: 'OR_ADV_1' });
    expect(payoutAudit.emitOrThrow).toHaveBeenCalledWith(expect.objectContaining({ eventType: 'payout_initiated' }));
  });

  it('refuses without sending anything when it is not the customer, not paid, disputed, or already sent', async () => {
    const cases: Array<[Parameters<typeof world>[0], string, unknown]> = [
      [{}, 'prov1', ForbiddenException],
      [{ txStatus: 'pending' }, 'client1', ConflictException],
      [{ txStatus: 'payout_pending' }, 'client1', ConflictException],
      [{ disputes: ['open'] }, 'client1', ConflictException],
      [{ advance: { status: 'paid_out' } }, 'client1', ConflictException],
      [{ advance: null }, 'client1', ConflictException],
    ];
    for (const [init, caller, err] of cases) {
      const w = world(init);
      await expect(w.service.release('p1', caller)).rejects.toBeInstanceOf(err as any);
      expect(w.daraja.b2cPayout).not.toHaveBeenCalled();
    }
  });

  it('loses cleanly to an approval that cancelled the advance a moment earlier', async () => {
    const w = world();
    // The final payout's claim lands between the release's read and its claim.
    w.payoutAudit.emitOrThrow.mockImplementation(async () => {
      w.state.advance!.status = 'cancelled';
      return null;
    });
    await expect(w.service.release('p1', 'client1')).rejects.toBeInstanceOf(ConflictException);
    expect(w.daraja.b2cPayout).not.toHaveBeenCalled();
    expect(w.state.advance!.status).toBe('cancelled');
  });

  it('holds it again when M-Pesa certainly did not take it, so the customer can retry', async () => {
    const w = world();
    w.daraja.b2cPayout.mockRejectedValue(new B2cNotSentError('Daraja 400: invalid initiator'));
    await expect(w.service.release('p1', 'client1')).rejects.toBeInstanceOf(BadRequestException);
    expect(w.state.advance).toMatchObject({ status: 'held', failure_reason: 'Daraja 400: invalid initiator' });
  });

  it('stays sending when the outcome is unknown, so nothing can pay twice', async () => {
    const w = world();
    w.daraja.b2cPayout.mockRejectedValue(new Error('timeout of 30000ms exceeded'));
    const r = await w.service.release('p1', 'client1');
    expect(r.status).toBe('sending');
    expect(w.state.advance!.status).toBe('sending');
    expect(String(w.state.advance!.failure_reason)).toMatch(/outcome unknown/);
  });
});

describe('the B2C result', () => {
  const sending = { status: 'sending', conversation_id: 'AG_ADV_1', originator_conversation_id: 'OR_ADV_1' };

  it('success: paid out, and both sides are told', async () => {
    const w = world({ advance: sending });
    await expect(w.service.settleByConversation({ conversationId: 'AG_ADV_1', resultCode: 0, resultDesc: 'ok', source: 'b2c-callback' })).resolves.toBe(true);
    expect(w.state.advance!.status).toBe('paid_out');
    const sent = w.notifications.sendMany.mock.calls[0][0] as Array<{ userId: string; body: string }>;
    expect(sent.map((n) => n.userId)).toEqual(['prov1', 'client1']);
    expect(sent[0].body).toContain('KES 4,000');
  });

  it('failure: held again while the payment is untouched, frozen if a dispute came meanwhile', async () => {
    const a = world({ advance: sending, txStatus: 'paid' });
    await a.service.settleByConversation({ conversationId: 'AG_ADV_1', resultCode: 2001, resultDesc: 'Invalid account', source: 'b2c-callback' });
    expect(a.state.advance).toMatchObject({ status: 'held', failure_reason: 'Invalid account' });
    expect(a.notifications.send).toHaveBeenCalledWith(expect.objectContaining({ userId: 'client1', type: 'materials_advance_failed' }));

    const b = world({ advance: sending, txStatus: 'disputed' });
    await b.service.settleByConversation({ conversationId: 'AG_ADV_1', resultCode: 1, resultDesc: 'Failed', source: 'b2c-callback' });
    expect(b.state.advance!.status).toBe('frozen');
  });

  it('a duplicate result changes nothing; a conversation that is not an advance is not claimed', async () => {
    const w = world({ advance: { ...sending, status: 'paid_out' } });
    await expect(w.service.settleByConversation({ conversationId: 'AG_ADV_1', resultCode: 1, resultDesc: 'late failure', source: 'b2c-callback' })).resolves.toBe(true);
    expect(w.state.advance!.status).toBe('paid_out');
    await expect(w.service.settleByConversation({ conversationId: 'AG_JOB_9', resultCode: 0, resultDesc: 'ok', source: 'b2c-callback' })).resolves.toBe(false);
  });
});

describe('the final payout and disputes', () => {
  it('subtracts a paid-out advance, cancels an unsent one, waits for one in flight', async () => {
    await expect(world({ advance: null }).service.prepareFinalPayout('tx1')).resolves.toBe(0);
    await expect(world({ advance: { status: 'paid_out' } }).service.prepareFinalPayout('tx1')).resolves.toBe(4_000);

    const held = world();
    await expect(held.service.prepareFinalPayout('tx1')).resolves.toBe(0);
    expect(held.state.advance!.status).toBe('cancelled');
    // Once cancelled, the customer can no longer send it.
    await expect(held.service.release('p1', 'client1')).rejects.toBeInstanceOf(ConflictException);

    await expect(world({ advance: { status: 'sending' } }).service.prepareFinalPayout('tx1')).rejects.toBeInstanceOf(ConflictException);
    await expect(world({ advance: { status: 'frozen' } }).service.prepareFinalPayout('tx1')).resolves.toBe(0);
  });

  it('a dispute freezes an unsent advance and leaves a sent one alone', async () => {
    const held = world();
    await held.service.freezeForDispute('tx1');
    expect(held.state.advance!.status).toBe('frozen');
    const paid = world({ advance: { status: 'paid_out' } });
    await paid.service.freezeForDispute('tx1');
    expect(paid.state.advance!.status).toBe('paid_out');
  });

  it('reads fail closed, except a table that does not exist yet', async () => {
    const missing = world({ advanceReadError: { code: 'PGRST205', message: "Could not find the table 'public.materials_advances'" } });
    await expect(missing.service.prepareFinalPayout('tx1')).resolves.toBe(0);
    const broken = world({ advanceReadError: { message: 'fetch failed' } });
    await expect(broken.service.prepareFinalPayout('tx1')).rejects.toThrow(/Could not read the materials advance/);
  });
});
