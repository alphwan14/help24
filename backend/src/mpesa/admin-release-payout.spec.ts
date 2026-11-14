import { Logger } from '@nestjs/common';
import { Call, fakeSupabase, opArgs } from '../moderation/fake-supabase.testspec';
import { ROLES_KEY } from '../admin/auth/roles.decorator';
import { MpesaController } from './mpesa.controller';
import { MpesaService } from './mpesa.service';

/**
 * POST /mpesa/release-payout, the hand-sent payout (2026-11-11). It was open
 * to any admin and left no record but a log line. Now: senior admins only, a
 * reason, and an admin_finance_actions row written BEFORE any money moves.
 */

const admin = { id: 'a-1', email: 'senior@help24.test', role: 'senior_admin' };

function build(w: { auditError?: string; tx?: Record<string, unknown> | null } = {}) {
  const { supabase, calls } = fakeSupabase((call: Call) => {
    if (call.table === 'escrow') return { data: { status: 'locked' } };
    if (call.table === 'admin_finance_actions') return w.auditError ? { error: { message: w.auditError } } : { data: null };
    return { data: null };
  });
  const transactions = {
    findLatestByPostId: jest.fn(async () => (w.tx === undefined ? { id: 't-1', status: 'paid', post_id: 'p-1' } : w.tx)),
  };
  const service = new MpesaService(
    {} as never, transactions as never, supabase as never, {} as never, {} as never, {} as never, {} as never, {} as never,
  );
  const order: string[] = [];
  const release = jest.spyOn(service, 'releasePayout').mockImplementation(async () => {
    if (calls.some((c) => c.table === 'admin_finance_actions')) order.push('audit');
    order.push('payout');
    return { message: 'Payout initiated.' } as never;
  });
  return { service, calls, release, order };
}

beforeEach(() => {
  for (const level of ['log', 'warn', 'error'] as const) jest.spyOn(Logger.prototype, level).mockImplementation(() => undefined);
});
afterEach(() => jest.restoreAllMocks());

describe('POST /mpesa/release-payout', () => {
  it('needs a senior admin', () => {
    expect(Reflect.getMetadata(ROLES_KEY, MpesaController.prototype.releasePayout)).toBe('senior_admin');
  });

  it('records who, why and the state before, then pays through the one payout path', async () => {
    const { service, calls, release, order } = build();
    await service.adminReleasePayout('p-1', admin, '  Provider says nothing came  ');
    expect(order).toEqual(['audit', 'payout']);
    const audit = calls.find((c) => c.table === 'admin_finance_actions');
    expect(opArgs(audit, 'insert')?.[0]).toMatchObject({
      action_type: 'payout_retried', transaction_id: 't-1', admin_id: 'a-1', admin_email: 'senior@help24.test', admin_role: 'senior_admin',
      reason: 'Provider says nothing came', previous_state: { transaction_status: 'paid', escrow_status: 'locked', via: 'mpesa/release-payout' },
    });
    expect(release).toHaveBeenCalledWith({ post_id: 'p-1' });
  });

  it('pays nothing if the record cannot be written', async () => {
    const { service, release } = build({ auditError: 'violates check constraint' });
    await expect(service.adminReleasePayout('p-1', admin, 'Provider says nothing came')).rejects.toMatchObject({ status: 503 });
    expect(release).not.toHaveBeenCalled();
  });

  it('pays nothing without a reason, or for a job with no payment', async () => {
    const a = build();
    await expect(a.service.adminReleasePayout('p-1', admin, ' ok ')).rejects.toMatchObject({ status: 400 });
    expect(a.release).not.toHaveBeenCalled();
    const b = build({ tx: null });
    await expect(b.service.adminReleasePayout('p-1', admin, 'Provider says nothing came')).rejects.toMatchObject({ status: 404 });
    expect(b.release).not.toHaveBeenCalled();
  });
});
