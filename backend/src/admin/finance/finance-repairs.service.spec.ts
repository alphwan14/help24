import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Call, fakeSupabase } from '../../moderation/fake-supabase.testspec';
import { MpesaService } from '../../mpesa/mpesa.service';
import { SupabaseService } from '../../supabase/supabase.service';
import { AdminAlertsService } from '../alerts/admin-alerts.service';
import { AdminContext } from '../auth/admin-role';
import { FinanceRepairsService } from './finance-repairs.service';

const admin = (role: AdminContext['role']): AdminContext => ({ id: `a-${role}`, email: `${role}@help24.test`, name: role, role });

interface World {
  rpcResult?: Record<string, unknown>;
  rpcError?: { message: string };
  releaseFails?: string;
  ruling?: Record<string, unknown> | null;
  tx?: Record<string, unknown> | null;
  escrow?: string;
  legs?: Array<Record<string, unknown>>;
  dispute?: Record<string, unknown> | null;
  history?: Array<Record<string, unknown>>;
}

function build(w: World = {}) {
  const { supabase, calls } = fakeSupabase((call: Call) => {
    if (call.rpc) return w.rpcError ? { error: w.rpcError } : { data: w.rpcResult ?? {} };
    switch (call.table) {
      case 'disputes':
        return { data: w.dispute === undefined ? { id: 'd-1', status: 'resolved', post_id: 'p-1', transaction_id: 't-1' } : w.dispute };
      case 'dispute_decisions':
        return { data: w.ruling === null ? [] : [w.ruling ?? { id: 'dec-1', decision_type: 'PARTIAL_SPLIT', provider_amount: 1250, client_refund_amount: 1250, created_at: '2026-06-18T10:00:00Z' }] };
      case 'transactions':
        return { data: w.tx === undefined ? { id: 't-1', status: 'refunded', total_paid: 2545 } : w.tx };
      case 'escrow':
        return { data: { status: w.escrow ?? 'refunded' } };
      case 'settlements':
        return { data: w.legs ?? [] };
      case 'admin_finance_actions':
        return { data: w.history ?? [] };
      default:
        return { data: null };
    }
  });
  const mpesa = {
    releasePayout: jest.fn().mockImplementation(async () => {
      if (w.releaseFails) throw new Error(w.releaseFails);
      return { ok: true };
    }),
  };
  const alerts = { invalidate: jest.fn() };
  const config = { get: (key: string, fallback?: unknown) => (key === 'MPESA_ENV' ? 'sandbox' : fallback) } as unknown as ConfigService;
  const service = new FinanceRepairsService(
    supabase as unknown as SupabaseService,
    mpesa as unknown as MpesaService,
    alerts as unknown as AdminAlertsService,
    config,
  );
  const rpc = (fn: string) => calls.find((c) => c.rpc === fn);
  return { service, calls, mpesa, alerts, rpc };
}

beforeEach(() => {
  jest.spyOn(Logger.prototype, 'log').mockImplementation(() => undefined);
  jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
});
afterEach(() => jest.restoreAllMocks());

describe('FinanceRepairsService.recordManualSettlement', () => {
  const dto = { direction: 'provider_payout' as const, reference: '  QK12ABC34 ', reason: ' Paid from the float by M-Pesa ' };

  it('is a senior decision — a support agent is refused before anything is written', async () => {
    const { service, rpc } = build();
    await expect(service.recordManualSettlement(admin('support_agent'), 't-1', dto)).rejects.toMatchObject({ status: 403 });
    expect(rpc('admin_record_manual_settlement')).toBeUndefined();
  });

  it('never sends an amount — the database takes it from the ruling — and refreshes the alerts', async () => {
    const { service, rpc, alerts } = build({ rpcResult: { settlement_id: 's-1', amount: 1250 } });
    await expect(service.recordManualSettlement(admin('senior_admin'), 't-1', dto)).resolves.toMatchObject({ amount: 1250 });
    const args = rpc('admin_record_manual_settlement')?.args ?? {};
    expect(args).toMatchObject({ p_admin_id: 'a-senior_admin', p_transaction_id: 't-1', p_direction: 'provider_payout',
      p_reference: 'QK12ABC34', p_reason: 'Paid from the float by M-Pesa', p_environment: 'sandbox' });
    expect(Object.keys(args).some((k) => k.includes('amount'))).toBe(false);
    expect(alerts.invalidate).toHaveBeenCalled();
  });

  it('a refusal from the database arrives as the right HTTP status with its sentence', async () => {
    const { service } = build({ rpcError: { message: 'HELP24_FINANCE_CONFLICT: this is already recorded as paid (completed)' } });
    await expect(service.recordManualSettlement(admin('super_admin'), 't-1', dto))
      .rejects.toMatchObject({ status: 409, response: { code: 'FINANCE_CONFLICT', message: 'This is already recorded as paid (completed).' } });
  });
});

describe('FinanceRepairsService.applyRecordedRuling', () => {
  const dto = { reason: 'Closed by the legacy path; the money never moved' };

  it('a FULL_RELEASE is unfrozen by the database, then paid out through the normal release path', async () => {
    const { service, mpesa, alerts } = build({ rpcResult: { phase: 'unfrozen_for_release', decision_type: 'FULL_RELEASE', post_id: 'p-9', needs_payout: true } });
    const r = await service.applyRecordedRuling(admin('senior_admin'), 'd-1', dto);
    expect(mpesa.releasePayout).toHaveBeenCalledWith({ post_id: 'p-9' });
    expect(r.payout).toMatchObject({ dispatched: true });
    expect(alerts.invalidate).toHaveBeenCalled();
  });

  it('if M-Pesa refuses the payout, the result says so plainly — and that applying again retries', async () => {
    const { service } = build({
      rpcResult: { phase: 'unfrozen_for_release', decision_type: 'FULL_RELEASE', post_id: 'p-9', needs_payout: true },
      releaseFails: 'No payout destination on file.',
    });
    const r = await service.applyRecordedRuling(admin('senior_admin'), 'd-1', dto);
    expect(r.payout).toMatchObject({ dispatched: false });
    expect(r.payout?.message).toContain('No payout destination on file.');
    expect(r.payout?.message).toContain('again to retry');
  });

  it('a refund ruling is applied in the database alone — no M-Pesa call', async () => {
    const { service, mpesa } = build({ rpcResult: { phase: 'applied', decision_type: 'PARTIAL_SPLIT', post_id: 'p-9', needs_payout: false } });
    const r = await service.applyRecordedRuling(admin('super_admin'), 'd-1', dto);
    expect(mpesa.releasePayout).not.toHaveBeenCalled();
    expect(r.payout).toBeNull();
  });

  it('is a senior decision', async () => {
    const { service, mpesa, rpc } = build();
    await expect(service.applyRecordedRuling(admin('support_agent'), 'd-1', dto)).rejects.toMatchObject({ status: 403 });
    expect(rpc('admin_apply_recorded_ruling')).toBeUndefined();
    expect(mpesa.releasePayout).not.toHaveBeenCalled();
  });
});

describe('FinanceRepairsService.money', () => {
  it('a split handed to finance: the refund leg is paid, the provider share still owed', async () => {
    const { service } = build({
      legs: [
        { id: 'l1', direction: 'client_refund', rail: 'manual', status: 'completed', amount: 1250, created_by: 'backfill', created_at: '2026-06-18T10:00:00Z', environment: 'sandbox' },
        { id: 'l2', direction: 'provider_payout', rail: 'mpesa_b2c', status: 'owed', amount: 1250, created_by: 'backfill', created_at: '2026-06-18T10:00:00Z', environment: 'sandbox' },
      ],
    });
    const m = await service.money('d-1');
    expect(m.shares).toEqual({ provider_payout: { amount: 1250, state: 'owed' }, client_refund: { amount: 1250, state: 'paid' } });
    expect(m.frozen).toBe(false);
    expect(m.can_apply_ruling).toBe(false);
    expect(m.environment).toBe('sandbox');
  });

  it('a closed dispute whose money is still "disputed" is frozen, and its ruling can be applied', async () => {
    const { service } = build({
      ruling: { id: 'dec-2', decision_type: 'FULL_RELEASE', provider_amount: 250, client_refund_amount: 0, created_at: '2026-06-09T10:00:00Z' },
      tx: { id: 't-1', status: 'disputed', total_paid: 270 },
      escrow: 'disputed',
    });
    const m = await service.money('d-1');
    expect(m.frozen).toBe(true);
    expect(m.can_apply_ruling).toBe(true);
    expect(m.shares.provider_payout.state).toBe('not_applicable'); // a release is paid by M-Pesa, not by hand
  });

  it('an unfrozen release that never went out can be retried — only after this tool unfroze it', async () => {
    const release = { id: 'dec-2', decision_type: 'FULL_RELEASE', provider_amount: 250, client_refund_amount: 0, created_at: '2026-06-09T10:00:00Z' };
    const paid = { id: 't-1', status: 'paid', total_paid: 270 };
    expect((await build({ ruling: release, tx: paid, escrow: 'locked' }).service.money('d-1')).can_apply_ruling).toBe(false);
    const after = build({ ruling: release, tx: paid, escrow: 'locked', history: [{ action_type: 'ruling_applied', admin_email: 'x', admin_role: 'senior_admin', reason: 'r', reference: null, new_state: { phase: 'unfrozen_for_release' }, created_at: '2026-09-27T10:00:00Z' }] });
    expect((await after.service.money('d-1')).can_apply_ruling).toBe(true);
  });

  it('an unknown dispute is a 404', async () => {
    await expect(build({ dispute: null }).service.money('d-x')).rejects.toMatchObject({ status: 404 });
  });
});
