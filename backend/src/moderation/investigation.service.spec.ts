import { Logger } from '@nestjs/common';
import { FirebaseAdminService } from '../notifications/firebase-admin.service';
import { AdminContext } from '../admin/auth/admin-role';
import { Call, fakeSupabase, opArgs } from './fake-supabase.testspec';
import { InvestigationService, idRange, targetLabel } from './investigation.service';
import { ReportEvidenceService } from './report-evidence.service';

const admin: AdminContext = { id: 'a1', email: 'support@help24.test', name: 'Support', role: 'support_agent' };
const REPORT_ID = '7f3a9c21-0b2d-4e5f-8a9b-0c1d2e3f4a5b';
const CHAT = 'c1c1c1c1-0000-4000-8000-000000000001';

function service(resolve: (call: Call) => { data?: unknown; error?: { message: string } | null; count?: number | null }) {
  const { supabase, calls } = fakeSupabase(resolve);
  const evidence = new ReportEvidenceService(supabase);
  const firebase = { app: null } as unknown as FirebaseAdminService;
  return { svc: new InvestigationService(supabase, evidence, firebase), calls };
}

beforeEach(() => jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined));
afterEach(() => jest.restoreAllMocks());

describe('InvestigationService — a failed query is never an answer', () => {
  it('summary throws when a count fails, rather than reporting zero open reports', async () => {
    const { svc } = service((call) =>
      call.table === 'user_reports' ? { error: { message: 'connection reset' } } : { count: 0 },
    );
    await expect(svc.summary(admin)).rejects.toMatchObject({ status: 503 });
  });
});

describe('InvestigationService.listReports', () => {
  it('the queue is most-serious-first, oldest-first, open reports only', async () => {
    const { svc, calls } = service(() => ({ data: [], count: 0 }));
    await svc.listReports({ status: 'open', sort: 'queue' }, admin);
    const main = calls[0];
    expect(opArgs(main, 'in')).toEqual(['status', ['new', 'under_review', 'action_required']]);
    const orders = main.ops.filter(([op]) => op === 'order').map(([, a]) => a);
    expect(orders).toEqual([['severity_rank', { ascending: false }], ['created_at', { ascending: true }]]);
  });

  it('a quoted reference searches by id range; free text cannot break the filter grammar', async () => {
    const { svc, calls } = service(() => ({ data: [], count: 0 }));
    await svc.listReports({ q: '7F3A9C21' }, admin);
    expect(opArgs(calls[0], 'gte')).toEqual(['id', '7f3a9c21-0000-0000-0000-000000000000']);
    expect(opArgs(calls[0], 'lte')).toEqual(['id', '7f3a9c21-ffff-ffff-ffff-ffffffffffff']);

    const second = service(() => ({ data: [], count: 0 }));
    await second.svc.listReports({ q: 'bob),status.eq.resolved' }, admin);
    const or = second.calls.find((c) => c.table === 'user_reports' && opArgs(c, 'or'));
    expect(String(opArgs(or, 'or')?.[0])).not.toMatch(/[()]status\.eq/);
  });

  it('"assigned to me" uses the caller\'s own admin id', async () => {
    const { svc, calls } = service(() => ({ data: [], count: 0 }));
    await svc.listReports({ assigned: 'me' }, admin);
    expect(calls[0].ops).toContainEqual(['eq', ['assigned_admin_id', 'a1']]);
  });
});

describe('InvestigationService.getReport — allegation, platform data and decisions stay apart', () => {
  const report = {
    id: REPORT_ID,
    reporter_id: 'u_alice',
    reported_user_id: 'u_bob',
    target_type: 'message',
    target_id: 'm1',
    message_id: 'm1',
    chat_id: CHAT,
    post_id: null,
    reason: 'threats',
    status: 'new',
    severity: 'high',
    created_at: '2026-09-20T10:00:00Z',
    target_snapshot: { content: 'Pay me or else', sent_at: '2026-09-20T09:00:00Z' },
    evidence: [{ path: 'reports/u_alice/0f0f0f0f-0000-4000-8000-000000000001.jpg', mime_type: 'image/jpeg' }],
  };

  function world(chatUsers: [string, string]) {
    return service((call) => {
      if (call.table === 'user_reports' && opArgs(call, 'maybeSingle')) return { data: report };
      if (call.table === 'users' && opArgs(call, 'maybeSingle')) return { data: { id: 'u_bob', name: 'Bob', created_at: '2026-01-01T00:00:00Z', email: 'bob@x', phone_number: '0712345678' } };
      if (call.table === 'users') return { data: [{ id: 'u_alice', name: 'Alice' }, { id: 'u_bob', name: 'Bob' }] };
      if (call.table === 'chats') return { data: { id: CHAT, user1: chatUsers[0], user2: chatUsers[1], post_id: null } };
      if (call.table === 'chat_messages' && opArgs(call, 'maybeSingle')) return { data: { id: 'm1', content: 'Pay me or else', deleted_for_everyone: false } };
      if (call.table === 'chat_messages') return { data: [{ id: 'm1', sender_id: 'u_bob', content: 'Pay me or else', created_at: '2026-09-20T09:00:00Z' }] };
      if (call.table === 'moderation_actions') {
        return { data: [
          { id: 'x1', action_type: 'note_added', created_at: '2026-09-21T00:00:00Z', reason: 'Internal note', internal_note: 'Checked' },
          { id: 'x2', action_type: 'report_triaged', created_at: '2026-09-20T12:00:00Z', reason: 'Status new → under review', admin_email: 'support@help24.test' },
        ] };
      }
      if (call.table === 'provider_reputation') return { data: null };
      return { data: [], count: 0 };
    });
  }

  it('returns the three layers, masks the phone, and splits notes from decisions', async () => {
    const { svc } = world(['u_alice', 'u_bob']);
    const view = await svc.getReport(REPORT_ID);

    expect(view.report.reference).toBe('7F3A9C21');
    expect(view.report.evidence[0].signed_url).toMatch(/^https:\/\/view\.test\/reports\/u_alice\//);
    expect(view.reported.user?.phone_number).toBe('•••• ••678');
    expect(view.notes.map((n: { id: string }) => n.id)).toEqual(['x1']);
    expect(view.decisions.map((d: { id: string }) => d.id)).toEqual(['x2']);

    const layers = new Set(view.timeline.map((e: { layer: string }) => e.layer));
    expect(layers).toEqual(new Set(['platform', 'allegation', 'decision']));
    const filed = view.timeline.find((e: { kind: string }) => e.kind === 'report_filed');
    expect(filed.layer).toBe('allegation');

    expect(view.conversation?.basis).toMatch(/participant/);
    expect(view.conversation?.messages[0]).toMatchObject({ from: 'reported', is_reported_message: true });
  });

  it('shows no conversation the reporter was not part of', async () => {
    const { svc } = world(['u_bob', 'u_carol']);
    const view = await svc.getReport(REPORT_ID);
    expect(view.conversation).toBeNull();
  });

  it('an unknown report is a 404', async () => {
    const { svc } = service(() => ({ data: null }));
    await expect(svc.getReport(REPORT_ID)).rejects.toMatchObject({ status: 404 });
  });
});

describe('helpers', () => {
  it('idRange spans every id with that prefix', () => {
    expect(idRange('ABCD')).toEqual({
      lo: 'abcd0000-0000-0000-0000-000000000000',
      hi: 'abcdffff-ffff-ffff-ffff-ffffffffffff',
    });
  });

  it('targetLabel names each kind of target from its snapshot', () => {
    expect(targetLabel('post', { title: 'Fix my sink' })).toBe('Fix my sink');
    expect(targetLabel('message', { content: 'hello' })).toBe('“hello”');
    expect(targetLabel('application', { post_title: 'Tiling' })).toBe('Application to “Tiling”');
    expect(targetLabel('user', {})).toBe('An account');
  });
});
