import { Logger } from '@nestjs/common';
import { AdminContext } from '../admin/auth/admin-role';
import { NotificationsService } from '../notifications/notifications.service';
import { AccountStateService } from './account-state.service';
import { SanctionDto } from './dto/moderation-admin.dto';
import { Call, fakeSupabase } from './fake-supabase.testspec';
import { ModerationService, sanctionEnd } from './moderation.service';

const admin = (role: AdminContext['role'], id = 'a-' + role): AdminContext => ({ id, email: `${role}@help24.test`, name: role, role });

interface World {
  userRole?: string;
  restrictionKind?: string;
  report?: Record<string, unknown> | null;
  rpcError?: { code?: string; message: string };
}

function build(world: World = {}) {
  const { supabase, calls } = fakeSupabase((call: Call) => {
    if (call.rpc) {
      if (world.rpcError) return { error: world.rpcError };
      if (call.rpc === 'moderation_apply_sanction') {
        return { data: { action_id: 'act-1', action_type: 'x', restriction_id: 'r-1', superseded: [], hidden_posts: [], report_resolved: false, state: { status: 'suspended', restrictions: [] } } };
      }
      if (call.rpc === 'moderation_set_content_state') return { data: { action_id: 'act-2', owner_user_id: 'u_bob' } };
      return { data: { action_id: 'act-3', user_id: 'u_bob' } };
    }
    if (call.table === 'users') return { data: { id: 'u_bob', role: world.userRole ?? 'user' } };
    if (call.table === 'account_restrictions') return { data: { id: 'r-1', user_id: 'u_bob', kind: world.restrictionKind ?? 'suspension' } };
    if (call.table === 'user_reports') return { data: world.report === undefined ? { id: 'rep-1', status: 'new', assigned_admin_id: null } : world.report };
    return { data: null };
  });
  const notifications = { send: jest.fn().mockResolvedValue(undefined) };
  const state = { invalidate: jest.fn() };
  const service = new ModerationService(
    supabase,
    notifications as unknown as NotificationsService,
    state as unknown as AccountStateService,
  );
  const rpcCall = (fn: string) => calls.find((c) => c.rpc === fn);
  return { service, calls, notifications, state, rpcCall };
}

const sanction = (over: Partial<SanctionDto>): SanctionDto =>
  Object.assign(new SanctionDto(), { kind: 'warning', reason: 'Please keep payments inside Help24', ...over });

beforeEach(() => {
  jest.spyOn(Logger.prototype, 'log').mockImplementation(() => undefined);
  jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
  jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
});
afterEach(() => jest.restoreAllMocks());

describe('ModerationService.applySanction — who may do what', () => {
  it('9: a support agent can warn', async () => {
    const { service, rpcCall } = build();
    await service.applySanction(admin('support_agent'), 'u_bob', sanction({ kind: 'warning' }));
    expect(rpcCall('moderation_apply_sanction')?.args).toMatchObject({ p_kind: 'warning', p_user_id: 'u_bob', p_admin_id: 'a-support_agent', p_ends_at: null });
  });

  it('a support agent cannot suspend; a senior admin cannot ban', async () => {
    await expect(build().service.applySanction(admin('support_agent'), 'u_bob', sanction({ kind: 'suspension', duration_days: 7 })))
      .rejects.toMatchObject({ status: 403 });
    await expect(build().service.applySanction(admin('senior_admin'), 'u_bob', sanction({ kind: 'ban' })))
      .rejects.toMatchObject({ status: 403 });
  });

  it('11: a super admin can ban', async () => {
    const { service, rpcCall } = build();
    await service.applySanction(admin('super_admin'), 'u_bob', sanction({ kind: 'ban', reason: 'Confirmed fraud against two clients' }));
    expect(rpcCall('moderation_apply_sanction')?.args).toMatchObject({ p_kind: 'ban', p_ends_at: null });
  });

  it("an administrator's own marketplace account needs a super admin, even for a warning", async () => {
    await expect(build({ userRole: 'admin' }).service.applySanction(admin('senior_admin'), 'u_bob', sanction({ kind: 'warning' })))
      .rejects.toMatchObject({ status: 403 });
    await expect(build({ userRole: 'admin' }).service.applySanction(admin('super_admin'), 'u_bob', sanction({ kind: 'warning' })))
      .resolves.toBeDefined();
  });

  it('10: a suspension end is computed on the server from the duration', async () => {
    const { service, rpcCall } = build();
    const before = Date.now();
    await service.applySanction(admin('senior_admin'), 'u_bob', sanction({ kind: 'suspension', duration_days: 7 }));
    const endsAt = Date.parse(rpcCall('moderation_apply_sanction')?.args?.p_ends_at as string);
    expect(endsAt - before).toBeGreaterThanOrEqual(7 * 86_400_000 - 1000);
    expect(endsAt - before).toBeLessThanOrEqual(7 * 86_400_000 + 5000);
  });

  it('refuses bad terms before touching the database', async () => {
    const cases: Array<Partial<SanctionDto>> = [
      { kind: 'suspension' },
      { kind: 'ban', duration_days: 3 },
      { kind: 'warning', duration_days: 3 },
      { kind: 'warning', hide_listings: true },
    ];
    for (const c of cases) {
      const { service, rpcCall } = build();
      await expect(service.applySanction(admin('super_admin'), 'u_bob', sanction(c))).rejects.toMatchObject({ status: 400 });
      expect(rpcCall('moderation_apply_sanction')).toBeUndefined();
    }
  });

  it('12/13: forgets the cached state so enforcement applies on the very next request', async () => {
    const { service, state } = build();
    await service.applySanction(admin('senior_admin'), 'u_bob', sanction({ kind: 'suspension', duration_days: 7 }));
    expect(state.invalidate).toHaveBeenCalledWith('u_bob');
  });

  it('23: tells the person in general terms — never the reason, never the reporter', async () => {
    const reason = 'Abusive messages to three clients, reported by Alice';
    for (const [kind, type] of [['warning', 'account_warning'], ['suspension', 'account_suspended'], ['ban', 'account_banned'], ['messaging', 'account_restricted'], ['marketplace', 'account_restricted']] as const) {
      const { service, notifications } = build();
      await service.applySanction(admin('super_admin'), 'u_bob', sanction({ kind, reason, duration_days: kind === 'suspension' ? 7 : undefined }));
      const sent = notifications.send.mock.calls[0][0];
      expect(sent.type).toBe(type);
      expect(sent.userId).toBe('u_bob');
      expect(JSON.stringify(sent)).not.toMatch(/Alice|Abusive/);
      expect(sent.data).toEqual({});
    }
  });

  it('passes the request id through to the ledger', async () => {
    const { service, rpcCall } = build();
    await service.applySanction(admin('support_agent'), 'u_bob', sanction({ kind: 'warning' }));
    expect(rpcCall('moderation_apply_sanction')?.args).toHaveProperty('p_request_id');
  });

  it('a database refusal becomes the right HTTP error', async () => {
    const { service } = build({ rpcError: { code: '23505', message: 'HELP24_MODERATION_CONFLICT: this account is already banned' } });
    await expect(service.applySanction(admin('super_admin'), 'u_bob', sanction({ kind: 'ban' }))).rejects.toMatchObject({ status: 409 });
  });
});

describe('ModerationService.liftRestriction', () => {
  it('lifting a ban needs a super admin; a suspension, a senior', async () => {
    await expect(build({ restrictionKind: 'ban' }).service.liftRestriction(admin('senior_admin'), 'r-1', { reason: 'Appeal upheld after review' }))
      .rejects.toMatchObject({ status: 403 });
    const { service, state, notifications } = build({ restrictionKind: 'suspension' });
    await service.liftRestriction(admin('senior_admin'), 'r-1', { reason: 'Appeal upheld after review' });
    expect(state.invalidate).toHaveBeenCalledWith('u_bob');
    expect(notifications.send.mock.calls[0][0]).toMatchObject({ type: 'account_restored', data: {} });
  });
});

describe('ModerationService — report triage', () => {
  it('a report someone else is working stays theirs, unless a super admin takes it', async () => {
    const assigned = { id: 'rep-1', status: 'under_review', assigned_admin_id: 'someone-else' };
    await expect(build({ report: assigned }).service.triageReport(admin('support_agent'), 'rep-1', { assign: 'me' }))
      .rejects.toMatchObject({ status: 409 });
    const { service, rpcCall } = build({ report: assigned });
    await service.triageReport(admin('super_admin'), 'rep-1', { assign: 'me' });
    expect(rpcCall('moderation_update_report')?.args).toMatchObject({ p_assign_to: 'a-super_admin' });
  });

  it('re-grading or moving someone else\'s report is the same lock as resolving it', async () => {
    const assigned = { id: 'rep-1', status: 'under_review', assigned_admin_id: 'someone-else' };
    await expect(build({ report: assigned }).service.triageReport(admin('support_agent'), 'rep-1', { severity: 'critical' }))
      .rejects.toMatchObject({ status: 409 });
    await expect(build({ report: assigned }).service.triageReport(admin('support_agent'), 'rep-1', { status: 'action_required' }))
      .rejects.toMatchObject({ status: 409 });
    const own = build({ report: { ...assigned, assigned_admin_id: 'a-support_agent' } });
    await own.service.triageReport(admin('support_agent'), 'rep-1', { severity: 'critical' });
    expect(own.rpcCall('moderation_update_report')?.args).toMatchObject({ p_severity: 'critical' });
    const senior = build({ report: assigned });
    await senior.service.triageReport(admin('senior_admin'), 'rep-1', { status: 'action_required' });
    expect(senior.rpcCall('moderation_update_report')?.args).toMatchObject({ p_status: 'action_required' });
  });

  it('closing someone else\'s report through a sanction is the same lock as resolving it', async () => {
    const assigned = { id: 'rep-1', status: 'under_review', assigned_admin_id: 'someone-else' };
    const warnAndClose = sanction({ kind: 'warning', report_id: '00000000-0000-4000-8000-00000000000a', resolve_report: true });
    const locked = build({ report: assigned });
    await expect(locked.service.applySanction(admin('support_agent'), 'u_bob', warnAndClose)).rejects.toMatchObject({ status: 409 });
    expect(locked.rpcCall('moderation_apply_sanction')).toBeUndefined();
    // Linking the report without closing it is fine: the case stays with its owner.
    const linked = build({ report: assigned });
    await linked.service.applySanction(admin('support_agent'), 'u_bob', { ...warnAndClose, resolve_report: false });
    expect(linked.rpcCall('moderation_apply_sanction')?.args).toMatchObject({ p_resolve_report: false });
  });

  it('assigning to another admin, and reopening a closed report, are senior decisions', async () => {
    await expect(build().service.triageReport(admin('support_agent'), 'rep-1', { assign_to: '00000000-0000-4000-8000-000000000001' }))
      .rejects.toMatchObject({ status: 403 });
    await expect(build({ report: { id: 'rep-1', status: 'dismissed', assigned_admin_id: null } })
      .service.triageReport(admin('support_agent'), 'rep-1', { status: 'under_review' }))
      .rejects.toMatchObject({ status: 403 });
  });

  it('8: resolving someone else\'s report needs a senior admin', async () => {
    const assigned = { id: 'rep-1', status: 'under_review', assigned_admin_id: 'someone-else' };
    await expect(build({ report: assigned }).service.resolveReport(admin('support_agent'), 'rep-1', { outcome: 'dismissed', reason: 'Insufficient evidence' }))
      .rejects.toMatchObject({ status: 409 });
    const { service, rpcCall } = build({ report: assigned });
    await service.resolveReport(admin('senior_admin'), 'rep-1', { outcome: 'dismissed', reason: 'Insufficient evidence' });
    expect(rpcCall('moderation_resolve_report')?.args).toMatchObject({ p_outcome: 'dismissed', p_reason: 'Insufficient evidence' });
  });

  it('an unknown report is a 404', async () => {
    await expect(build({ report: null }).service.resolveReport(admin('super_admin'), 'nope', { outcome: 'resolved', reason: 'Handled' }))
      .rejects.toMatchObject({ status: 404 });
  });
});

describe('ModerationService — content', () => {
  it('a hidden listing is explained to its owner; a hidden message is not announced', async () => {
    const post = build();
    await post.service.setContentState(admin('support_agent'), 'post', 'p-1', 'remove', { reason: 'Misleading payment instructions' });
    expect(post.notifications.send.mock.calls[0][0]).toMatchObject({ userId: 'u_bob', type: 'content_removed', data: {} });

    const message = build();
    await message.service.setContentState(admin('support_agent'), 'message', 'm-1', 'remove', { reason: 'Threatening message to a client' });
    expect(message.notifications.send).not.toHaveBeenCalled();
  });
});

describe('sanctionEnd', () => {
  it('partial restrictions may be open-ended', () => {
    expect(sanctionEnd('messaging')).toBeNull();
    expect(sanctionEnd('marketplace', 14)).not.toBeNull();
  });
});
