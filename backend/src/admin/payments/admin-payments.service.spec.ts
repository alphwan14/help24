import { Logger } from '@nestjs/common';
import { Call, fakeSupabase, opArgs } from '../../moderation/fake-supabase.testspec';
import { SupabaseService } from '../../supabase/supabase.service';
import { NotificationsService } from '../../notifications/notifications.service';
import { MpesaService } from '../../mpesa/mpesa.service';
import { JobsService } from '../../jobs/jobs.service';
import { DisputesService } from '../disputes/disputes.service';
import { AdminContext } from '../auth/admin-role';
import { AdminPaymentsService } from './admin-payments.service';

const admin = (role: AdminContext['role']): AdminContext => ({ id: `a-${role}`, email: `${role}@help24.test`, name: role, role });

interface World {
  tx?: Record<string, unknown>;
  post?: Record<string, unknown>;
  escrow?: string;
  completion?: Record<string, unknown> | null;
  disputes?: Array<Record<string, unknown>>;
  auditError?: string;
  disputesError?: string;
  postMoved?: boolean;
  approveWins?: boolean;
}

function build(w: World = {}) {
  const tx = { id: 't-1', post_id: 'p-1', status: 'paid', amount: 2500, fee: 45, total_paid: 2545, created_at: '2026-11-01T09:00:00Z', ...w.tx };
  const post = { id: 'p-1', title: 'Fix the sink', status: 'assigned', author_user_id: 'u-client', selected_provider_id: 'u-pro', created_at: '2026-11-01T08:00:00Z', ...w.post };
  const completion = w.completion === undefined
    ? { id: 'c-1', status: 'pending_approval', created_at: '2026-11-02T10:00:00Z', provider_user_id: 'u-pro', client_user_id: 'u-client' }
    : w.completion;

  const { supabase, calls } = fakeSupabase((call: Call) => {
    const has = (op: string) => call.ops.some(([o]) => o === op);
    switch (call.table) {
      case 'transactions':
        return has('maybeSingle') ? { data: tx } : { data: [tx] };
      case 'posts':
        if (has('update')) return { data: w.postMoved === false ? [] : [{ id: 'p-1' }] };
        return { data: post };
      case 'escrow':
        return { data: { status: w.escrow ?? 'locked', released_at: null, created_at: '2026-11-01T09:00:05Z' } };
      case 'job_completions':
        return { data: completion };
      case 'disputes':
        if (w.disputesError) return { error: { message: w.disputesError } };
        return { data: has('update') ? null : w.disputes ?? [] };
      case 'admin_finance_actions':
        if (has('insert')) return w.auditError ? { error: { message: w.auditError } } : { data: null };
        return { data: [] };
      default:
        return { data: null };
    }
  });

  const order: string[] = [];
  const recordAudit = () => {
    if (calls.some((c) => c.table === 'admin_finance_actions' && c.ops.some(([o]) => o === 'insert'))) order.push('audit');
  };
  const mpesa = {
    releasePayout: jest.fn(async () => { recordAudit(); order.push('payout'); return { message: 'Payout sent to M-Pesa.' }; }),
    reconcilePayout: jest.fn(async () => { recordAudit(); order.push('reconcile'); return { message: 'Asked M-Pesa.' }; }),
  };
  const jobs = { approveCompletion: jest.fn(async () => { recordAudit(); order.push('approve'); return w.approveWins ?? true; }) };
  const disputes = { createDispute: jest.fn(async () => { recordAudit(); order.push('dispute'); return { dispute_id: 'd-9', deduped: false }; }) };
  const notifications = { sendMany: jest.fn(async () => undefined) };

  const service = new AdminPaymentsService(
    supabase as unknown as SupabaseService,
    notifications as unknown as NotificationsService,
    mpesa as unknown as MpesaService,
    jobs as unknown as JobsService,
    disputes as unknown as DisputesService,
  );
  const audits = () => calls.filter((c) => c.table === 'admin_finance_actions' && c.ops.some(([o]) => o === 'insert'));
  return { service, calls, mpesa, jobs, disputes, notifications, order, audits };
}

beforeEach(() => {
  for (const level of ['log', 'warn', 'error'] as const) jest.spyOn(Logger.prototype, level).mockImplementation(() => undefined);
});
afterEach(() => jest.restoreAllMocks());

describe('AdminPaymentsService', () => {
  it('approve now: records who and why FIRST, then approves through the one approval path as "admin"', async () => {
    const { service, jobs, order, audits, notifications } = build();
    await expect(service.approveCompletion('t-1', admin('senior_admin'), 'Client confirmed by phone')).resolves.toMatchObject({ ok: true });
    expect(order).toEqual(['audit', 'approve']);
    expect(opArgs(audits()[0], 'insert')?.[0]).toMatchObject({
      action_type: 'completion_approved', transaction_id: 't-1', admin_id: 'a-senior_admin', admin_role: 'senior_admin',
      reason: 'Client confirmed by phone', previous_state: { transaction_status: 'paid', escrow_status: 'locked', completion_status: 'pending_approval' },
    });
    expect(jobs.approveCompletion).toHaveBeenCalledWith(expect.objectContaining({ completionId: 'c-1', providerId: 'u-pro', clientUserId: 'u-client', by: 'admin' }));
    expect(notifications.sendMany).toHaveBeenCalled();
  });

  it('if the record cannot be written, nothing happens', async () => {
    const { service, jobs } = build({ auditError: 'violates check constraint' });
    await expect(service.approveCompletion('t-1', admin('senior_admin'), 'Client confirmed by phone')).rejects.toMatchObject({ status: 503 });
    expect(jobs.approveCompletion).not.toHaveBeenCalled();
  });

  it('a support agent cannot move money; nothing is recorded or done', async () => {
    const { service, jobs, audits } = build();
    await expect(service.approveCompletion('t-1', admin('support_agent'), 'Client confirmed by phone')).rejects.toMatchObject({ status: 403 });
    expect(audits()).toHaveLength(0);
    expect(jobs.approveCompletion).not.toHaveBeenCalled();
  });

  it('an action the payment no longer fits is refused (stale page)', async () => {
    const { service, mpesa, audits } = build();
    // Not approved yet, so there is no payout to retry.
    await expect(service.retryPayout('t-1', admin('super_admin'), 'Provider says nothing came')).rejects.toMatchObject({ status: 409 });
    expect(audits()).toHaveLength(0);
    expect(mpesa.releasePayout).not.toHaveBeenCalled();
  });

  it('a reason is required', async () => {
    const { service, jobs } = build();
    await expect(service.approveCompletion('t-1', admin('senior_admin'), '  ok ')).rejects.toMatchObject({ status: 400 });
    expect(jobs.approveCompletion).not.toHaveBeenCalled();
  });

  it('retry payout: recorded, then the one payout path', async () => {
    const { service, mpesa, order } = build({ completion: { id: 'c-1', status: 'approved', created_at: '2026-11-02T10:00:00Z', provider_user_id: 'u-pro', client_user_id: 'u-client' } });
    await service.retryPayout('t-1', admin('senior_admin'), 'Provider says nothing came');
    expect(order).toEqual(['audit', 'payout']);
    expect(mpesa.releasePayout).toHaveBeenCalledWith({ post_id: 'p-1' });
  });

  it('a payment whose disputes cannot be read shows nothing and offers nothing', async () => {
    const { service } = build({ disputesError: 'connection reset' });
    await expect(service.detail('t-1', admin('super_admin'))).rejects.toMatchObject({ status: 503 });
  });

  it('opening a dispute for the provider: recorded, raised in their name, marked as opened by Help24', async () => {
    const { service, disputes, order, calls } = build();
    await expect(service.openDispute('t-1', admin('support_agent'), 'provider', 'Provider says the client refuses to approve'))
      .resolves.toMatchObject({ dispute_id: 'd-9' });
    expect(order).toEqual(['audit', 'dispute']);
    expect(disputes.createDispute).toHaveBeenCalledWith(expect.objectContaining({
      post_id: 'p-1', raised_by_user_id: 'u-pro', raised_by_role: 'provider',
      reason: 'Opened by Help24 for the provider: Provider says the client refuses to approve',
    }));
    const mark = calls.find((c) => c.table === 'disputes' && c.ops.some(([o]) => o === 'update'));
    expect(opArgs(mark, 'update')?.[0]).toEqual({ opened_by_admin_id: 'a-support_agent' });
  });

  it('cancel hire only moves a job still assigned to that provider', async () => {
    const unpaid = { tx: { status: 'failed' }, completion: null };
    const { service, calls } = build(unpaid);
    await expect(service.cancelHire('t-1', admin('senior_admin'), 'Client asked to choose someone else')).resolves.toMatchObject({ ok: true });
    const upd = calls.find((c) => c.table === 'posts' && c.ops.some(([o]) => o === 'update'));
    expect(opArgs(upd, 'update')?.[0]).toEqual({ status: 'open', selected_provider_id: null });
    expect(upd?.ops.filter(([o]) => o === 'eq').map(([, a]) => a)).toEqual([['id', 'p-1'], ['status', 'assigned'], ['selected_provider_id', 'u-pro']]);

    const raced = build({ ...unpaid, postMoved: false });
    await expect(raced.service.cancelHire('t-1', admin('senior_admin'), 'Client asked to choose someone else')).rejects.toMatchObject({ status: 409 });
  });
});
