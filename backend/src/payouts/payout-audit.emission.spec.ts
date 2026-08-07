import { PayoutAuditService } from './payout-audit.service';

/**
 * The emission contract, as tests.
 *
 * The rule these defend is the one that is easiest to "simplify" wrongly:
 * emission failure is handled DIFFERENTLY depending on whether money has
 * already moved.
 *
 *   before money moves — refuse. Nothing is lost, and an unauditable payout is
 *                        exactly what this system exists to prevent.
 *   after  money moves — record the loss and carry on. Refusing does not un-send
 *                        the funds; it only destroys the evidence that they went.
 */

function buildService(opts: { enabled: boolean; failInsert?: boolean }) {
  const inserted: Record<string, unknown>[] = [];
  const supabase = {
    client: {
      from: () => ({
        insert: (row: Record<string, unknown>) => {
          inserted.push(row);
          return {
            select: () => ({
              single: () =>
                Promise.resolve(
                  opts.failInsert
                    ? { data: null, error: { message: 'audit table unavailable' } }
                    : { data: { event_id: 'evt-generated' }, error: null },
                ),
            }),
          };
        },
      }),
    },
  };

  const prev = process.env.PAYOUT_DESTINATIONS_ENABLED;
  process.env.PAYOUT_DESTINATIONS_ENABLED = opts.enabled ? 'true' : 'false';
  const service = new PayoutAuditService(supabase as any);
  process.env.PAYOUT_DESTINATIONS_ENABLED = prev;

  return { service, inserted };
}

const EVENT = {
  providerUserId: 'provider-1',
  eventType: 'payout_completed' as const,
  actorType: 'processor' as const,
};

describe('payout audit emission', () => {
  describe('the feature flag', () => {
    it('writes nothing at all while disabled', async () => {
      // Migrations may not be applied on every environment. An unconditional
      // insert would turn every payout into a 500 against a missing table.
      const { service, inserted } = buildService({ enabled: false });
      await expect(service.emit(EVENT)).resolves.toBeNull();
      await expect(service.emitOrThrow(EVENT)).resolves.toBeNull();
      expect(inserted).toHaveLength(0);
    });
  });

  describe('after money has moved — emit()', () => {
    it('records the event and returns its id', async () => {
      const { service, inserted } = buildService({ enabled: true });
      await expect(service.emit(EVENT)).resolves.toBe('evt-generated');
      expect(inserted).toHaveLength(1);
    });

    it('NEVER throws when the audit write fails', async () => {
      // The funds are already gone. Throwing here would convert an audit
      // outage into a payment outage without recovering a single shilling.
      const { service } = buildService({ enabled: true, failInsert: true });
      await expect(service.emit(EVENT)).resolves.toBeNull();
    });
  });

  describe('before money moves — emitOrThrow()', () => {
    it('propagates the failure so the caller aborts', async () => {
      const { service } = buildService({ enabled: true, failInsert: true });
      await expect(
        service.emitOrThrow({ ...EVENT, eventType: 'payout_initiated' }),
      ).rejects.toThrow(/payout audit insert failed/);
    });

    it('returns the id on success so a snapshot can reference it', async () => {
      const { service } = buildService({ enabled: true });
      await expect(
        service.emitOrThrow({ ...EVENT, eventType: 'payout_snapshot_captured' }),
      ).resolves.toBe('evt-generated');
    });
  });

  describe('what the application is NOT allowed to supply', () => {
    it('never sends chain_seq, prev_event_hash or event_hash', async () => {
      // The database seals the chain. A chain the application could write is a
      // chain the application could forge.
      const { service, inserted } = buildService({ enabled: true });
      await service.emit(EVENT);
      expect(inserted[0]).not.toHaveProperty('chain_seq');
      expect(inserted[0]).not.toHaveProperty('prev_event_hash');
      expect(inserted[0]).not.toHaveProperty('event_hash');
    });

    it('omits occurred_at unless given, so the column default applies', async () => {
      const { service, inserted } = buildService({ enabled: true });
      await service.emit(EVENT);
      expect(inserted[0]).not.toHaveProperty('occurred_at');
    });

    it('sends occurred_at when a processor reports an earlier time', async () => {
      // A Daraja callback describes something that happened before we heard of
      // it. Two clocks exist precisely so that gap stays visible.
      const { service, inserted } = buildService({ enabled: true });
      const when = new Date('2026-08-07T09:00:00.000Z');
      await service.emit({ ...EVENT, occurredAt: when });
      expect(inserted[0].occurred_at).toBe('2026-08-07T09:00:00.000Z');
    });

    it('allows a pre-generated event id so a snapshot can point at it', async () => {
      const { service, inserted } = buildService({ enabled: true });
      await service.emitOrThrow({ ...EVENT, eventId: 'evt-pre' });
      expect(inserted[0].event_id).toBe('evt-pre');
    });
  });

  describe('the row shape', () => {
    it('carries every forensic field, nulling what is absent', async () => {
      const { service, inserted } = buildService({ enabled: true });
      await service.emit({
        providerUserId: 'p1',
        eventType: 'payout_failed',
        actorType: 'processor',
        transactionId: 'tx-1',
        reason: 'insufficient funds',
        metadata: { result_code: 17 },
      });
      const row = inserted[0];
      expect(row.provider_user_id).toBe('p1');
      expect(row.event_type).toBe('payout_failed');
      expect(row.actor_type).toBe('processor');
      expect(row.transaction_id).toBe('tx-1');
      expect(row.reason).toBe('insufficient funds');
      expect(row.metadata).toEqual({ result_code: 17 });
      // Absent references are explicit nulls, never undefined — an omitted key
      // and a known-absent one mean different things to a reviewer.
      expect(row.payout_destination_id).toBeNull();
      expect(row.escrow_id).toBeNull();
      expect(row.verification_id).toBeNull();
    });
  });
});
