import { NotificationPayload, NotificationsService } from '../../notifications/notifications.service';
import { SupabaseService } from '../../supabase/supabase.service';
import { AdminContext } from '../auth/admin-role';
import { DAILY_CAP, RequestRescueService } from './request-rescue.service';

type Filters = Array<[string, string, unknown]>;
type Tables = Record<string, (filters: Filters) => { data: unknown; error: { message: string } | null }>;

/** A PostgREST-shaped fake: records filters, answers per table. */
function fakeDb(tables: Tables): SupabaseService {
  return {
    client: {
      from(table: string) {
        const filters: Filters = [];
        const q = {
          select: () => q,
          eq: (c: string, v: unknown) => (filters.push(['eq', c, v]), q),
          or: (v: string) => (filters.push(['or', 'or', v]), q),
          in: (c: string, v: unknown) => (filters.push(['in', c, v]), q),
          gte: (c: string, v: unknown) => (filters.push(['gte', c, v]), q),
          maybeSingle: async () => {
            const r = tables[table](filters);
            return { data: Array.isArray(r.data) ? (r.data[0] ?? null) : r.data, error: r.error };
          },
          then: (resolve: (v: unknown) => void) => resolve(tables[table](filters)),
        };
        return q;
      },
    },
  } as unknown as SupabaseService;
}

const admin: AdminContext = { id: 'adm-1', email: 'ops@example.test', name: 'Ops', role: 'support_agent' };
const POST = '11111111-2222-4333-8444-555555555555';
const openRequest = {
  id: POST, title: 'Fix a leaking sink', location: 'Nyali', category: 'Plumbing', type: 'request',
  status: 'open', archived_at: null, selected_provider_id: null, author_user_id: 'client',
};

function setup(over: Partial<Tables> = {}, post: Record<string, unknown> = openRequest) {
  const sent: NotificationPayload[] = [];
  const tables: Tables = {
    posts: () => ({ data: post, error: null }),
    users: () => ({ data: ['client', 'p1', 'p2', 'p3', 'p4', 'p5', 'p6'].map((id) => ({ id, fcm_tokens: [] })), error: null }),
    fcm_tokens: () => ({ data: [{ user_id: 'p1' }], error: null }),
    moderation_account_state: () => ({ data: [{ user_id: 'p4', account_status: 'suspended' }], error: null }),
    applications: () => ({ data: [{ applicant_user_id: 'p2' }], error: null }),
    notifications: (f) =>
      f.some(([op]) => op === 'or')
        ? { data: [{ user_id: 'p3' }], error: null }
        : { data: Array.from({ length: DAILY_CAP }, () => ({ user_id: 'p5' })), error: null },
    ...over,
  };
  const notifications = { sendMany: async (p: NotificationPayload[]) => void sent.push(...p) } as unknown as NotificationsService;
  return { service: new RequestRescueService(fakeDb(tables), notifications), sent };
}

describe('RequestRescueService', () => {
  it('tells only the providers it may, and says why it skipped the rest', async () => {
    const { service, sent } = setup();
    const out = await service.notifyProviders(admin, POST, ['client', 'p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'ghost']);

    expect(sent.map((s) => s.userId)).toEqual(['p1', 'p6']);
    expect(out).toEqual({
      notified: 2,
      withPush: 1, // p1 has a device in fcm_tokens; p6 gets it in the inbox
      skipped: [
        { userId: 'client', reason: 'is_client' },
        { userId: 'p2', reason: 'applied' },
        { userId: 'p3', reason: 'already_notified' },
        { userId: 'p4', reason: 'unavailable' },
        { userId: 'p5', reason: 'daily_limit' },
        { userId: 'ghost', reason: 'no_account' },
      ],
    });
  });

  it('the push names the request and carries only its id and the sender', async () => {
    const { service, sent } = setup();
    await service.notifyProviders(admin, POST, ['p1']);
    expect(sent[0]).toMatchObject({
      type: 'request_match',
      body: 'Fix a leaking sink — Nyali. Open Help24 to send an offer.',
      data: { listing_id: POST, sent_by: 'adm-1' },
    });
  });

  it('refuses when the request is no longer open, and notifies nobody', async () => {
    for (const post of [
      { ...openRequest, status: 'assigned' },
      { ...openRequest, selected_provider_id: 'p9' },
      { ...openRequest, archived_at: '2026-10-01T00:00:00Z' },
      { ...openRequest, type: 'offer' },
    ]) {
      const { service, sent } = setup({}, post);
      await expect(service.notifyProviders(admin, POST, ['p1'])).rejects.toMatchObject({ status: 409 });
      expect(sent).toHaveLength(0);
    }
  });

  it('a failed read of any limit notifies nobody — it is never read as "no limit"', async () => {
    const { service, sent } = setup({ notifications: () => ({ data: null, error: { message: 'timeout' } }) });
    await expect(service.notifyProviders(admin, POST, ['p1'])).rejects.toMatchObject({ status: 503 });
    expect(sent).toHaveLength(0);
  });

  it('bounds the list', async () => {
    const { service } = setup();
    await expect(service.notifyProviders(admin, POST, [])).rejects.toMatchObject({ status: 400 });
    await expect(
      service.notifyProviders(admin, POST, Array.from({ length: 26 }, (_, i) => `p${i}`)),
    ).rejects.toMatchObject({ status: 400 });
  });
});
