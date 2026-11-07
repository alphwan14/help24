import { Logger } from '@nestjs/common';
import { Call, fakeSupabase } from '../moderation/fake-supabase.testspec';
import { NotificationsService } from '../notifications/notifications.service';
import { AdminContext } from '../admin/auth/admin-role';
import { VerificationsService } from './verifications.service';
import { VerificationsSweepService, vettingSweepEnabled } from './verifications-sweep.service';
import { decisionNotice, REJECTION_REASONS } from './verification-rules';

const admin: AdminContext = { id: 'admin-1', email: 'a@help24.test', name: 'A', role: 'support_agent' };

beforeEach(() => {
  jest.spyOn(Logger.prototype, 'log').mockImplementation(() => undefined);
  jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
  jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
});
afterEach(() => jest.restoreAllMocks());

function service(resolve: (c: Call) => { data?: unknown; error?: { message?: string } | null }) {
  const fake = fakeSupabase(resolve);
  const send = jest.fn().mockResolvedValue(undefined);
  const svc = new VerificationsService(fake.supabase, { send } as unknown as NotificationsService);
  return { svc, send, ...fake };
}

const reviewed = (over: Record<string, unknown> = {}) => ({
  id: 'v-1', user_id: 'u_nanny', kind: 'id', document_type: 'national_id', status: 'approved',
  expires_at: null, listings_changed: 0, ...over,
});

describe('VerificationsService.review', () => {
  it('records the decision through the database function with the reviewer, then tells the provider', async () => {
    const { svc, send, calls } = service((c) => (c.rpc === 'review_provider_verification' ? { data: reviewed() } : { data: null }));
    const r = await svc.review('v-1', { decision: 'approve' }, admin);
    expect(r.status).toBe('approved');
    expect(calls.find((c) => c.rpc === 'review_provider_verification')?.args).toEqual({
      p_id: 'v-1', p_decision: 'approve', p_reason: null, p_reviewer: 'admin-1',
    });
    expect(send).toHaveBeenCalledWith(expect.objectContaining({
      userId: 'u_nanny', type: 'verification_approved', title: 'Your ID is verified',
      data: { screen: 'verification', kind: 'id', status: 'approved' },
    }));
  });

  it('refuses a rejection without a reason before touching the database', async () => {
    const { svc, calls } = service(() => ({ data: null }));
    await expect(svc.review('v-1', { decision: 'reject', reason: '   ' }, admin)).rejects.toMatchObject({ status: 400 });
    expect(calls).toHaveLength(0);
  });

  it('sends the provider the reason they were turned down for', async () => {
    const { svc, send } = service(() => ({ data: reviewed({ status: 'rejected' }) }));
    await svc.review('v-1', { decision: 'reject', reason: REJECTION_REASONS[0] }, admin);
    expect(send.mock.calls[0][0].body).toContain('blurred or too dark');
    expect(send.mock.calls[0][0].type).toBe('verification_rejected');
  });

  it('a failed push never undoes a recorded decision', async () => {
    const { svc, send } = service(() => ({ data: reviewed() }));
    send.mockRejectedValueOnce(new Error('FCM down'));
    await expect(svc.review('v-1', { decision: 'approve' }, admin)).resolves.toMatchObject({ status: 'approved' });
  });

  it.each([
    ['HELP24_VERIFICATION_ALREADY_REVIEWED: this submission was already approved', 409],
    ['HELP24_VERIFICATION_NOT_FOUND', 404],
    ["HELP24_VERIFICATION_INVALID: approve this provider's ID first", 400],
  ])('maps "%s" to HTTP %i', async (message, status) => {
    const { svc, send } = service(() => ({ error: { message } }));
    await expect(svc.review('v-1', { decision: 'approve' }, admin)).rejects.toMatchObject({ status });
    expect(send).not.toHaveBeenCalled();
  });

  it('says what to do next for an ID check that comes first', async () => {
    const { svc } = service(() => ({ error: { message: "HELP24_VERIFICATION_INVALID: approve this provider's ID first" } }));
    await expect(svc.review('v-1', { decision: 'approve' }, admin)).rejects.toThrow("Approve this provider's ID first.");
  });
});

describe('VerificationsService.get', () => {
  const row = {
    id: 'v-1', user_id: 'u_nanny', kind: 'id', document_type: 'national_id',
    files: ['u_nanny/a.jpg', 'u_nanny/b.jpg', 'u_nanny/c.jpg'], status: 'pending',
    submitted_at: '2026-11-07T08:00:00Z', reviewed_at: null, reviewed_by: null,
    rejection_reason: null, expires_at: null, files_deleted_at: null,
  };

  it('signs a short-lived link for each document, named by what it is, and never returns the paths', async () => {
    const { svc, signed } = service((c) => {
      if (c.table === 'provider_verifications' && c.ops.some(([op]) => op === 'maybeSingle')) return { data: row };
      if (c.table === 'provider_verifications') return { data: [row] };
      if (c.rpc === 'provider_vetting_state') return { data: [{ id_verified: false, care_status: 'none', care_expires_at: null }] };
      return { data: [] };
    });
    const r = await svc.get('v-1');
    expect(r.files.map((f) => f.role)).toEqual(['Front', 'Back', 'Selfie holding the ID']);
    expect(signed.map((s) => s.bucket)).toEqual(['provider-verifications', 'provider-verifications', 'provider-verifications']);
    // Only inside the signed link, never as a bare storage path.
    expect(JSON.stringify(r)).not.toContain('"u_nanny/a.jpg"');
    expect(r.state).toEqual({ id_verified: false, care_status: 'none', care_expires_at: null });
  });

  it('offers no links once the documents were deleted', async () => {
    const gone = { ...row, status: 'approved', files_deleted_at: '2026-12-07T00:00:00Z' };
    const { svc, signed } = service((c) => {
      if (c.table === 'provider_verifications' && c.ops.some(([op]) => op === 'maybeSingle')) return { data: gone };
      return { data: [] };
    });
    const r = await svc.get('v-1');
    expect(r.files).toEqual([]);
    expect(signed).toHaveLength(0);
  });

  it('404s an unknown submission', async () => {
    const { svc } = service(() => ({ data: null }));
    await expect(svc.get('v-x')).rejects.toMatchObject({ status: 404 });
  });
});

describe('decisionNotice', () => {
  it('a receipt names the date the certificate is due', () => {
    const n = decisionNotice({ kind: 'care', document_type: 'receipt', status: 'approved', expires_at: '2026-12-07T09:00:00Z' });
    expect(n.title).toBe('Receipt accepted — certificate pending');
    expect(n.body).toContain('7 December 2026');
  });

  it('a certificate completes the Care check', () => {
    expect(decisionNotice({ kind: 'care', document_type: 'certificate', status: 'approved' }).title).toBe('Care check complete');
  });
});

describe('VerificationsSweepService', () => {
  const now = new Date('2026-12-10T00:00:00Z');

  function sweeper(purgeRows: unknown[], sweepResult: unknown = 2) {
    const fake = fakeSupabase((c) => {
      if (c.rpc === 'vetting_sweep') return { data: sweepResult };
      if (c.table === 'provider_verifications' && c.ops.some(([op]) => op === 'select')) return { data: purgeRows };
      return { data: null };
    });
    return { svc: new VerificationsSweepService(fake.supabase), ...fake };
  }

  it('runs the database sweep, then deletes documents decided more than 30 days ago and stamps them', async () => {
    const { svc, calls, removed } = sweeper([{ id: 'v-1', files: ['u/a.jpg', 'u/b.jpg'] }]);
    await expect(svc.sweep(now)).resolves.toEqual({ hidden: 2, purged: 1 });

    const query = calls.find((c) => c.table === 'provider_verifications' && c.ops.some(([op]) => op === 'select'))!;
    expect(query.ops).toEqual(expect.arrayContaining([
      ['in', ['status', ['approved', 'rejected']]],
      ['is', ['files_deleted_at', null]],
      ['lt', ['reviewed_at', '2026-11-10T00:00:00.000Z']],
    ]));
    expect(removed).toEqual([
      { bucket: 'provider-verifications', path: 'u/a.jpg' },
      { bucket: 'provider-verifications', path: 'u/b.jpg' },
    ]);
    const stamp = calls.find((c) => c.table === 'provider_verifications' && c.ops.some(([op]) => op === 'update'))!;
    expect(stamp.ops).toEqual(expect.arrayContaining([
      ['update', [{ files_deleted_at: now.toISOString() }]],
      ['eq', ['id', 'v-1']],
      ['is', ['files_deleted_at', null]],
    ]));
  });

  it('leaves a row for the next sweep when Storage refuses, but treats "not found" as already deleted', async () => {
    const refused = sweeper([{ id: 'v-1', files: ['u/a.jpg'] }]);
    refused.storageErrors.remove = 'Service unavailable';
    await expect(refused.svc.sweep(now)).resolves.toMatchObject({ purged: 0 });

    const gone = sweeper([{ id: 'v-2', files: ['u/a.jpg'] }]);
    gone.storageErrors.remove = 'Object not found';
    await expect(gone.svc.sweep(now)).resolves.toMatchObject({ purged: 1 });
  });

  it('a failed database sweep does not stop the purge', async () => {
    const fake = fakeSupabase((c) => {
      if (c.rpc === 'vetting_sweep') return { error: { message: 'boom' } };
      if (c.table === 'provider_verifications' && c.ops.some(([op]) => op === 'select')) return { data: [{ id: 'v-1', files: [] }] };
      return { data: null };
    });
    await expect(new VerificationsSweepService(fake.supabase).sweep(now)).resolves.toEqual({ hidden: 0, purged: 1 });
  });

  it('has a kill switch', () => {
    expect(vettingSweepEnabled({})).toBe(true);
    expect(vettingSweepEnabled({ VETTING_SWEEP_ENABLED: 'false' })).toBe(false);
    expect(vettingSweepEnabled({ VETTING_SWEEP_ENABLED: ' FALSE ' })).toBe(false);
  });
});
