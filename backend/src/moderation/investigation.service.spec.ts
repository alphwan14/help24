import { Logger } from '@nestjs/common';
import { FirebaseAdminService } from '../notifications/firebase-admin.service';
import { AdminContext } from '../admin/auth/admin-role';
import { Call, fakeSupabase, opArgs } from './fake-supabase.testspec';
import { InvestigationService, idRange, targetLabel } from './investigation.service';
import { ReportEvidenceService } from './report-evidence.service';
import { ChatAttachmentLinksService, attachmentObject } from './chat-attachment-links.service';

const admin: AdminContext = { id: 'a1', email: 'support@help24.test', name: 'Support', role: 'support_agent' };
const REPORT_ID = '7f3a9c21-0b2d-4e5f-8a9b-0c1d2e3f4a5b';
const CHAT = 'c1c1c1c1-0000-4000-8000-000000000001';
const OTHER_CHAT = 'c2c2c2c2-0000-4000-8000-000000000002';
const MSG = 'd1d1d1d1-0000-4000-8000-000000000001';
const MSG2 = 'd2d2d2d2-0000-4000-8000-000000000002';

function service(resolve: (call: Call) => { data?: unknown; error?: { message: string } | null; count?: number | null }) {
  const { supabase, calls, signed, missing } = fakeSupabase(resolve);
  const evidence = new ReportEvidenceService(supabase);
  const firebase = { app: null } as unknown as FirebaseAdminService;
  return {
    svc: new InvestigationService(supabase, evidence, firebase, new ChatAttachmentLinksService(supabase)),
    calls,
    signed,
    missing,
  };
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

describe('chat attachments in an investigation — admins get signed links, never raw references', () => {
  const report = {
    id: REPORT_ID,
    reporter_id: 'u_alice',
    reported_user_id: 'u_bob',
    target_type: 'message',
    target_id: MSG,
    message_id: MSG,
    chat_id: CHAT,
    post_id: null,
    reason: 'scam',
    status: 'new',
    severity: 'high',
    created_at: '2026-10-04T10:00:00Z',
    // As migration 114 snapshotted it — the reference the row had at the time.
    target_snapshot: {
      content: 'Image',
      type: 'image',
      attachment_url: `https://ref.supabase.test/storage/v1/object/public/post-images/chat_attachments/${CHAT}/0e0e0e0e-0000-4000-8000-000000000e0e.jpg`,
      sent_at: '2026-10-04T09:00:00Z',
    },
    evidence: [],
  };
  const thread = [
    { id: MSG, sender_id: 'u_bob', content: 'Image', type: 'image', attachment_url: `chat-attachments/${CHAT}/${MSG}.jpg`, created_at: '2026-10-04T09:00:00Z' },
    // A row whose stored reference names another conversation's file.
    { id: MSG2, sender_id: 'u_bob', content: 'File', type: 'file', attachment_url: `chat-attachments/${OTHER_CHAT}/${MSG2}.pdf`, created_at: '2026-10-04T09:01:00Z' },
    { id: 'm3', sender_id: 'u_alice', content: 'hello', type: 'text', attachment_url: null, created_at: '2026-10-04T09:02:00Z' },
  ];

  function world() {
    return service((call) => {
      if (call.table === 'user_reports' && opArgs(call, 'maybeSingle')) return { data: report };
      if (call.table === 'chats') return { data: { id: CHAT, user1: 'u_alice', user2: 'u_bob', post_id: null } };
      if (call.table === 'chat_messages' && opArgs(call, 'maybeSingle')) return { data: { ...thread[0], chat_id: CHAT, deleted_for_everyone: false } };
      if (call.table === 'chat_messages') return { data: thread };
      if (call.table === 'users' && opArgs(call, 'maybeSingle')) return { data: { id: 'u_bob', name: 'Bob' } };
      return { data: [], count: 0 };
    });
  }

  it('signs each message’s own object in the private bucket, and nothing else', async () => {
    const { svc, signed } = world();
    const view = await svc.getReport(REPORT_ID);
    const messages = view.conversation?.messages as unknown as Array<{ id: string; attachment_view_url: string | null }>;
    expect(messages.find((m) => m.id === MSG)?.attachment_view_url).toBe(`https://view.test/${CHAT}/u_bob/${MSG}.jpg`);
    expect(messages.find((m) => m.id === MSG2)?.attachment_view_url).toBeNull();
    expect(messages.find((m) => m.id === 'm3')?.attachment_view_url).toBeNull();
    expect((view.target.live as { attachment_view_url: string }).attachment_view_url).toBe(`https://view.test/${CHAT}/u_bob/${MSG}.jpg`);
    for (const s of signed) {
      expect(s.bucket).toBe('chat-attachments');
      expect(s.path.startsWith(`${CHAT}/`)).toBe(true);
    }
    expect(signed.some((s) => s.path.includes(OTHER_CHAT))).toBe(false);
  });

  it('the report snapshot still opens after the file moved to private storage', async () => {
    const { svc } = world();
    const view = await svc.getReport(REPORT_ID);
    expect(view.target.attachment_view_url).toBe(`https://view.test/${CHAT}/u_bob/${MSG}.jpg`);
  });

  it('before migration, a legacy attachment falls back to its old address', async () => {
    const { svc, missing } = world();
    missing.add(`chat-attachments/${CHAT}/u_bob/${MSG}.jpg`);
    const view = await svc.getReport(REPORT_ID);
    expect(view.target.attachment_view_url).toBe(report.target_snapshot.attachment_url);
  });
});

describe('attachmentObject — the stored reference is never followed as a pointer', () => {
  const SB = 'https://ref.supabase.test';
  const row = (attachment_url: string, extra: Record<string, unknown> = {}) => ({ id: MSG, chat_id: CHAT, sender_id: 'u_bob', type: 'image', attachment_url, ...extra });

  it('accepts only its own chat and message', () => {
    expect(attachmentObject(row(`chat-attachments/${CHAT}/${MSG}.jpg`), SB)).toEqual({ key: `${CHAT}/u_bob/${MSG}.jpg`, ext: 'jpg', legacyUrl: null });
    expect(attachmentObject(row(`chat-attachments/${OTHER_CHAT}/${MSG}.jpg`), SB)).toBeNull();
    expect(attachmentObject(row(`chat-attachments/${CHAT}/${MSG2}.jpg`), SB)).toBeNull();
    expect(attachmentObject(row(`chat-attachments/${CHAT}/${MSG}.pdf`), SB)).toBeNull();
    expect(attachmentObject(row(`dispute-evidence/reports/u/x.jpg`), SB)).toBeNull();
    expect(attachmentObject(row(`${SB}/storage/v1/object/public/post-images/chat_attachments/${OTHER_CHAT}/x.jpg`), SB)).toBeNull();
    expect(attachmentObject(row(`https://evil.test/storage/v1/object/public/post-images/chat_attachments/${CHAT}/x.jpg`), SB)).toBeNull();
    expect(attachmentObject(row(`${SB}/storage/v1/object/public/post-images/chat_attachments/${CHAT}/x.jpeg`), SB)).toEqual({
      key: `${CHAT}/u_bob/${MSG}.jpg`,
      ext: 'jpg',
      legacyUrl: `${SB}/storage/v1/object/public/post-images/chat_attachments/${CHAT}/x.jpeg`,
    });
    expect(attachmentObject(row(`chat-attachments/${CHAT}/${MSG}.jpg`, { type: 'text' }), SB)).toBeNull();
    // The sender names the folder; a row without a usable one serves nothing.
    expect(attachmentObject(row(`chat-attachments/${CHAT}/${MSG}.jpg`, { sender_id: 'u_alice' }), SB)?.key).toBe(`${CHAT}/u_alice/${MSG}.jpg`);
    expect(attachmentObject(row(`chat-attachments/${CHAT}/${MSG}.jpg`, { sender_id: '../x' }), SB)).toBeNull();
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
