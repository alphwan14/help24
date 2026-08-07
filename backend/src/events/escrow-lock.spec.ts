import { EventProcessorService } from './event-processor.service';

/**
 * `lockEscrowForPayment` — the repair path that had never once succeeded.
 *
 * The original implementation upserted with `onConflict: 'transaction_id'`
 * against a table whose only unique constraint is on `post_id`, so Postgres
 * rejected every call. Six funded transactions reached production with their
 * escrow row still bound to a failed earlier attempt.
 *
 * These tests pin the four decisions the replacement makes, because each one
 * is a way to lose or resurrect money if it is wrong.
 */

type EscrowRow = { id: string; transaction_id: string | null; status: string };

/**
 * Minimal stand-in for the two PostgREST chains this method uses:
 *   escrow:       select→eq→maybeSingle · insert · update→eq→eq
 *   transactions: select→eq→maybeSingle
 */
function fakeSupabase(state: {
  escrow: EscrowRow | null;
  incumbentTxStatus?: string | null;
  readError?: string;
  writeError?: string;
}) {
  const calls = { inserted: [] as unknown[], updated: [] as unknown[] };

  const client = {
    from(table: string) {
      if (table === 'transactions') {
        return {
          select: () => ({
            eq: () => ({
              maybeSingle: async () => ({
                data:
                  state.incumbentTxStatus === undefined
                    ? null
                    : state.incumbentTxStatus === null
                      ? null
                      : { status: state.incumbentTxStatus },
                error: null,
              }),
            }),
          }),
        };
      }

      // escrow
      return {
        select: () => ({
          eq: () => ({
            maybeSingle: async () => ({
              data: state.escrow,
              error: state.readError ? { message: state.readError } : null,
            }),
          }),
        }),
        insert: async (row: unknown) => {
          calls.inserted.push(row);
          return { error: state.writeError ? { message: state.writeError } : null };
        },
        update: (patch: unknown) => ({
          eq: () => ({
            eq: async () => {
              calls.updated.push(patch);
              return { error: state.writeError ? { message: state.writeError } : null };
            },
          }),
        }),
      };
    },
  };

  return { supabase: { client } as never, calls };
}

/** Builds the service with only the collaborator this method touches. */
function serviceWith(supabase: never): EventProcessorService {
  return new EventProcessorService(
    {} as never, // events
    supabase,
    {} as never, // notifications
    {} as never, // mpesa
    {} as never, // reputation
  );
}

/** The method is private by design; the spec reaches it deliberately. */
function lock(
  service: EventProcessorService,
  postId: string,
  txId: string,
  amount: number,
): Promise<void> {
  return (
    service as unknown as {
      lockEscrowForPayment(p: string, t: string, a: number): Promise<void>;
    }
  ).lockEscrowForPayment(postId, txId, amount);
}

describe('lockEscrowForPayment — no escrow row yet', () => {
  it('inserts a locked row for this transaction', async () => {
    const { supabase, calls } = fakeSupabase({ escrow: null });
    await lock(serviceWith(supabase), 'post-1', 'tx-1', 500);

    expect(calls.inserted).toEqual([
      { post_id: 'post-1', transaction_id: 'tx-1', amount: 500, status: 'locked' },
    ]);
    expect(calls.updated).toEqual([]);
  });

  it('throws when the insert fails, so the event retries', async () => {
    const { supabase } = fakeSupabase({ escrow: null, writeError: 'boom' });
    await expect(lock(serviceWith(supabase), 'post-1', 'tx-1', 500)).rejects.toThrow(/boom/);
  });

  it('throws when the read fails rather than assuming there is no row', async () => {
    // Assuming "no row" on a read error would insert a duplicate and violate
    // UNIQUE (post_id) — or worse, succeed against a stale replica.
    const { supabase } = fakeSupabase({ escrow: null, readError: 'connection reset' });
    await expect(lock(serviceWith(supabase), 'post-1', 'tx-1', 500)).rejects.toThrow(
      /connection reset/,
    );
  });
});

describe('lockEscrowForPayment — the row is already ours', () => {
  it('does nothing, so a replayed event is a no-op', async () => {
    const { supabase, calls } = fakeSupabase({
      escrow: { id: 'e1', transaction_id: 'tx-1', status: 'locked' },
    });
    await lock(serviceWith(supabase), 'post-1', 'tx-1', 500);

    expect(calls.inserted).toEqual([]);
    expect(calls.updated).toEqual([]);
  });

  it('is a no-op even once the money has been released', async () => {
    // The eleven historical payment.success events sit in dead-letter and are
    // replayable by hand. Replaying one must not touch a released escrow.
    const { supabase, calls } = fakeSupabase({
      escrow: { id: 'e1', transaction_id: 'tx-1', status: 'released' },
    });
    await lock(serviceWith(supabase), 'post-1', 'tx-1', 500);

    expect(calls.updated).toEqual([]);
  });
});

describe('lockEscrowForPayment — the row belongs to a failed attempt', () => {
  it('re-points it to the successful transaction', async () => {
    // This is the production bug, exactly: escrow left behind by a failed
    // attempt, and a later successful transaction with no escrow of its own.
    const { supabase, calls } = fakeSupabase({
      escrow: { id: 'e1', transaction_id: 'failed-tx', status: 'locked' },
      incumbentTxStatus: 'failed',
    });
    await lock(serviceWith(supabase), 'post-1', 'good-tx', 800);

    expect(calls.updated).toEqual([
      { transaction_id: 'good-tx', amount: 800, status: 'locked' },
    ]);
    expect(calls.inserted).toEqual([]);
  });

  it('re-points when the incumbent transaction no longer exists', async () => {
    const { supabase, calls } = fakeSupabase({
      escrow: { id: 'e1', transaction_id: 'vanished-tx', status: 'locked' },
      incumbentTxStatus: null,
    });
    await lock(serviceWith(supabase), 'post-1', 'good-tx', 800);

    expect(calls.updated).toHaveLength(1);
  });
});

describe('lockEscrowForPayment — refuses to steal live or settled escrow', () => {
  it.each(['pending', 'paid', 'payout_pending', 'disputed'])(
    'leaves escrow alone when the incumbent transaction is %s',
    async (incumbentTxStatus) => {
      // Two funded payments on one post should be impossible (initiate blocks
      // it). If it happens anyway, that is a state to report, not overwrite.
      const { supabase, calls } = fakeSupabase({
        escrow: { id: 'e1', transaction_id: 'other-tx', status: 'locked' },
        incumbentTxStatus,
      });
      await lock(serviceWith(supabase), 'post-1', 'new-tx', 800);

      expect(calls.updated).toEqual([]);
      expect(calls.inserted).toEqual([]);
    },
  );

  it.each(['released', 'refunded'])(
    'never re-points escrow that is already %s',
    async (status) => {
      const { supabase, calls } = fakeSupabase({
        escrow: { id: 'e1', transaction_id: 'other-tx', status },
        incumbentTxStatus: 'failed', // even though the incumbent failed
      });
      await lock(serviceWith(supabase), 'post-1', 'new-tx', 800);

      expect(calls.updated).toEqual([]);
    },
  );
});
