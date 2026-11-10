import { ConfigService } from '@nestjs/config';
import { HttpException } from '@nestjs/common';
import { SupabaseService } from '../../supabase/supabase.service';
import { OutboundEmail, SupportMailerService } from '../../support/support-mailer.service';
import { AdminAlertsService } from '../alerts/admin-alerts.service';
import { AdminAlert } from '../alerts/alert-rules';
import { AdminContext } from '../auth/admin-role';
import { AdminAlertEmailsService } from './admin-alert-emails.service';
import { alert } from './alert-email.fixtures';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Row = Record<string, any>;

/** The PostgREST chains the service uses, over in-memory rows. */
function fakeDb(tables: Record<string, Row[]>, missing: Set<string>) {
  function from(table: string) {
    const rows = () => (tables[table] ??= []);
    let op: 'select' | 'update' | 'upsert' | 'delete' = 'select';
    let payload: any = null;
    let conflict = '';
    let single = false;
    const filters: Array<(r: Row) => boolean> = [];
    const exec = () => {
      if (missing.has(table)) return { data: null, error: { code: 'PGRST205', message: `Could not find the table 'public.${table}'` } };
      if (op === 'upsert') {
        for (const p of Array.isArray(payload) ? payload : [payload]) {
          const existing = rows().find((r) => r[conflict] === p[conflict]);
          if (existing) Object.assign(existing, p);
          else rows().push({ ...p });
        }
        return { data: null, error: null };
      }
      const matched = rows().filter((r) => filters.every((f) => f(r)));
      if (op === 'update') {
        matched.forEach((r) => Object.assign(r, payload));
        return { data: null, error: null };
      }
      if (op === 'delete') {
        tables[table] = rows().filter((r) => !matched.includes(r));
        return { data: null, error: null };
      }
      return { data: single ? matched[0] ?? null : matched, error: null };
    };
    const b: any = {
      select: () => b,
      update: (p: any) => ((op = 'update'), (payload = p), b),
      upsert: (p: any, o: { onConflict: string }) => ((op = 'upsert'), (payload = p), (conflict = o.onConflict), b),
      delete: () => ((op = 'delete'), b),
      eq: (c: string, v: unknown) => (filters.push((r) => r[c] === v), b),
      in: (c: string, vs: unknown[]) => (filters.push((r) => vs.includes(r[c])), b),
      maybeSingle: () => ((single = true), b),
      then: (res: any, rej: any) => Promise.resolve(exec()).then(res, rej),
    };
    return b;
  }
  return { client: { from } } as unknown as SupabaseService;
}

const ALICE = { id: 'a0000000-0000-4000-8000-000000000001', email: 'alice@example.com', active: true };
const BOB = { id: 'a0000000-0000-4000-8000-000000000002', email: 'bob@example.com', active: true };
const GONE = { id: 'a0000000-0000-4000-8000-000000000003', email: 'gone@example.com', active: false };
const asAdmin = (a: Row): AdminContext => ({ id: a.id, email: a.email, name: 'Alice', role: 'super_admin' });

function setup(opts: { missing?: string[]; configured?: boolean; settings?: Row[] } = {}) {
  const tables: Record<string, Row[]> = {
    admin_users: [ALICE, BOB, GONE],
    admin_alert_email_settings: opts.settings ?? [],
    admin_alert_email_state: [],
  };
  let current: { alerts: AdminAlert[]; unavailable: Array<{ source: string; reason: string }> } = { alerts: [], unavailable: [] };
  const alerts = { list: jest.fn(async () => ({ generated_at: '', ...current })) } as unknown as AdminAlertsService;
  const sent: OutboundEmail[] = [];
  const mailer = {
    configured: opts.configured ?? true,
    send: jest.fn(async (m: OutboundEmail) => (sent.push(m), { providerId: 're_1' })),
  } as unknown as SupportMailerService;
  const config = { get: () => undefined } as unknown as ConfigService;
  const service = new AdminAlertEmailsService(fakeDb(tables, new Set(opts.missing ?? [])), alerts, mailer, config);
  return {
    service,
    tables,
    sent,
    setAlerts: (a: AdminAlert[], unavailable: Array<{ source: string; reason: string }> = []) => (current = { alerts: a, unavailable }),
  };
}

const MORNING = new Date('2026-11-11T06:00:00Z'); // 09:00 Nairobi
const EARLY = new Date('2026-11-11T03:00:00Z'); // 06:00 Nairobi

describe('AdminAlertEmailsService — the sweep', () => {
  it('emails each active admin once about what is new, then stays quiet while nothing changes', async () => {
    const { service, sent, setAlerts } = setup();
    setAlerts([alert()]);
    expect(await service.sweep(EARLY)).toEqual({ sent: 2 });
    expect(sent.map((m) => m.to).sort()).toEqual(['alice@example.com', 'bob@example.com']); // never the deactivated admin
    expect(sent[0]).toMatchObject({ from: 'Help24 Admin <alerts@help24.co.ke>', subject: 'Help24: 1 support conversation is waiting for a reply' });
    expect(sent[0].replyTo).toBeUndefined();

    expect(await service.sweep(EARLY)).toEqual({ sent: 0 });

    setAlerts([alert({ count: 2, latest_at: '2026-11-11T02:30:00.000Z' })]); // a member wrote in
    expect(await service.sweep(EARLY)).toEqual({ sent: 2 });
    expect(sent).toHaveLength(4);
  });

  it('respects each admin: only their kinds, nothing when off', async () => {
    const { service, sent, setAlerts } = setup({
      settings: [
        { admin_id: ALICE.id, frequency: 'instant', categories: ['financial'], last_digest_on: null },
        { admin_id: BOB.id, frequency: 'off', categories: ['support'], last_digest_on: null },
      ],
    });
    setAlerts([alert(), alert({ id: 'payout_failed', category: 'financial', priority: 'high', title: '1 payout failed — provider not paid' })]);
    await service.sweep(EARLY);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({ to: 'alice@example.com', subject: 'Help24: 1 payout failed: provider not paid' });
  });

  it('a morning summary goes once a day from 08:00 Nairobi, listing everything still waiting', async () => {
    const { service, tables, sent, setAlerts } = setup({
      settings: [
        { admin_id: ALICE.id, frequency: 'daily', categories: ['support', 'marketplace'], last_digest_on: '2026-11-10' },
        { admin_id: BOB.id, frequency: 'off', categories: [], last_digest_on: null },
      ],
    });
    setAlerts([alert(), alert({ id: 'requests_unanswered', category: 'marketplace', priority: 'low', title: '3 requests have had no response for a day', count: 3 })]);
    expect(await service.sweep(EARLY)).toEqual({ sent: 0 }); // 06:00 Nairobi: not yet
    expect(await service.sweep(MORNING)).toEqual({ sent: 1 });
    expect(sent[0].subject).toBe('Help24 morning summary: 2 things need attention'); // low priority included here
    expect(tables.admin_alert_email_settings[0].last_digest_on).toBe('2026-11-11');
    expect(await service.sweep(new Date('2026-11-11T12:00:00Z'))).toEqual({ sent: 0 });
  });

  it('a cleared alert is forgotten, so it is announced again if it comes back; not when a source was unreadable', async () => {
    const { service, sent, setAlerts, tables } = setup();
    setAlerts([alert()]);
    await service.sweep(EARLY);
    setAlerts([], [{ source: 'support', reason: 'This check could not run.' }]);
    await service.sweep(EARLY);
    expect(tables.admin_alert_email_state.map((r) => r.alert_id)).toEqual(['support_waiting']); // kept: absence proves nothing
    setAlerts([alert()]);
    await service.sweep(EARLY);
    expect(sent).toHaveLength(2); // not announced again

    setAlerts([]);
    await service.sweep(EARLY);
    expect(tables.admin_alert_email_state).toHaveLength(0);
    setAlerts([alert()]);
    await service.sweep(EARLY);
    expect(sent).toHaveLength(4);
  });

  it('does nothing, quietly, before migration 141 or without a Resend key', async () => {
    const noTables = setup({ missing: ['admin_alert_email_state', 'admin_alert_email_settings'] });
    noTables.setAlerts([alert()]);
    expect(await noTables.service.sweep(EARLY)).toMatchObject({ sent: 0, skipped: 'Migration 141 is not applied.' });

    const noMail = setup({ configured: false });
    noMail.setAlerts([alert()]);
    expect(await noMail.service.sweep(EARLY)).toMatchObject({ sent: 0 });
    expect(noMail.sent).toHaveLength(0);
  });
});

describe('AdminAlertEmailsService — each admin\'s own setting', () => {
  it('no row reads as right away for every kind; saving stores only known kinds', async () => {
    const { service, tables } = setup();
    expect(await service.settingsFor(asAdmin(ALICE))).toEqual({
      frequency: 'instant', categories: ['financial', 'trust_safety', 'support', 'marketplace'], email: 'alice@example.com', available: true,
    });
    const saved = await service.saveSettings(asAdmin(ALICE), { frequency: 'daily', categories: ['support', 'financial'] });
    expect(saved).toMatchObject({ frequency: 'daily', categories: ['financial', 'support'] });
    expect(tables.admin_alert_email_settings[0].last_digest_on).toMatch(/^\d{4}-\d{2}-\d{2}$/); // the first summary is tomorrow
    await expect(service.saveSettings(asAdmin(ALICE), { frequency: 'hourly', categories: [] })).rejects.toThrow('Choose how often.');
    await expect(service.saveSettings(asAdmin(ALICE), { frequency: 'off', categories: ['gossip'] })).rejects.toThrow('Unknown kind of alert.');
  });

  it('before migration 141 the setting reads as unavailable and cannot be saved', async () => {
    const { service } = setup({ missing: ['admin_alert_email_settings'] });
    expect((await service.settingsFor(asAdmin(ALICE))).available).toBe(false);
    await expect(service.saveSettings(asAdmin(ALICE), { frequency: 'off', categories: [] })).rejects.toThrow('not set up');
  });

  it('a test email goes to the admin\'s own address, at most once a minute', async () => {
    const { service, sent } = setup();
    expect(await service.sendTest(asAdmin(ALICE))).toEqual({ sent: true, to: 'alice@example.com' });
    expect(sent[0]).toMatchObject({ to: 'alice@example.com', subject: 'Help24: test alert email' });
    await expect(service.sendTest(asAdmin(ALICE))).rejects.toBeInstanceOf(HttpException);
    expect(sent).toHaveLength(1);
  });
});
