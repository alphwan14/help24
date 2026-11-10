import { BadRequestException, ConflictException } from '@nestjs/common';
import { DecisionsService } from './decisions.service';

/**
 * Dispute rulings after a Materials Advance (migration 139).
 *
 * Owner decision 2026-11-10: if the job fails after the advance went to the
 * fundi, the customer gets back everything Help24 still holds, fee included.
 * So every ruling works on the HELD amount: job minus the paid-out advance.
 * A KES 10,000 job (fee 500, total 10,500) with a KES 4,000 advance paid out
 * leaves 6,000 held; a full refund is 6,000 + 500 = 6,500.
 */

function build(advance: { status: string; amount: number } | null) {
  const inserted: Array<Record<string, unknown>> = [];
  const client = {
    from(table: string) {
      const chain: any = {
        select: () => chain,
        eq: () => chain,
        insert: (row: Record<string, unknown>) => {
          inserted.push(row);
          return chain;
        },
        single: () =>
          Promise.resolve(
            table === 'posts'
              ? { data: { title: 'Roof repair', author_user_id: 'client1', selected_provider_id: 'prov1' }, error: null }
              : table === 'transactions'
                ? { data: { id: 'tx1', status: 'disputed', amount: 10_000, total_paid: 10_500 }, error: null }
                : { data: { id: 'dec1' }, error: null },
          ),
      };
      return chain;
    },
  };
  const disputes = {
    requireDispute: jest.fn().mockResolvedValue({ id: 'd1', status: 'under_review', post_id: 'p1', transaction_id: 'tx1', assigned_admin_id: 'a1' }),
    systemMessage: jest.fn(),
  };
  const advances = { forTransaction: jest.fn().mockResolvedValue(advance) };
  const service = new DecisionsService(
    { client } as any,
    { sendMany: jest.fn() } as any,
    { releasePayout: jest.fn() } as any,
    { emit: jest.fn() } as any,
    disputes as any,
    advances as any,
  );
  // The ledger row is what this suite checks; the money execution has its own tests.
  jest.spyOn(service as any, 'applyFinancial').mockResolvedValue(undefined);
  jest.spyOn(service as any, 'applyEscalation').mockResolvedValue(undefined);
  return { service, inserted };
}

const admin = { id: 'a1', email: 'admin@help24.io', name: 'Admin', role: 'senior_admin' } as any;
const paidOut = { status: 'paid_out', amount: 4_000 };

describe('rulings after a Materials Advance', () => {
  it('a full refund returns the held 60% plus the fee', async () => {
    const { service, inserted } = build(paidOut);
    await service.decide('d1', { decision_type: 'FULL_REFUND', reasoning: 'Work not done' } as any, admin);
    expect(inserted[0]).toMatchObject({ decision_type: 'FULL_REFUND', provider_amount: 0, client_refund_amount: 6_500 });
  });

  it('a full release pays the provider only what is still held', async () => {
    const { service, inserted } = build(paidOut);
    await service.decide('d1', { decision_type: 'FULL_RELEASE', reasoning: 'Work done' } as any, admin);
    expect(inserted[0]).toMatchObject({ provider_amount: 6_000, client_refund_amount: 0 });
  });

  it('a split can never hand out more than is held', async () => {
    const { service } = build(paidOut);
    await expect(
      service.decide('d1', { decision_type: 'PARTIAL_SPLIT', provider_amount: 4_000, client_refund_amount: 3_000, reasoning: 'Half done' } as any, admin),
    ).rejects.toBeInstanceOf(BadRequestException);
  });

  it('without an advance, nothing changes: the full total comes back', async () => {
    const { service, inserted } = build(null);
    await service.decide('d1', { decision_type: 'FULL_REFUND', reasoning: 'Work not done' } as any, admin);
    expect(inserted[0]).toMatchObject({ client_refund_amount: 10_500 });
  });

  it('no money ruling while an advance is still in flight; escalation is still allowed', async () => {
    const { service } = build({ status: 'sending', amount: 4_000 });
    await expect(service.decide('d1', { decision_type: 'FULL_REFUND', reasoning: 'x' } as any, admin)).rejects.toBeInstanceOf(ConflictException);
    const ok = build({ status: 'sending', amount: 4_000 });
    await expect(ok.service.decide('d1', { decision_type: 'ESCALATE', reasoning: 'Wait for M-Pesa' } as any, admin)).resolves.toBeDefined();
  });
});
