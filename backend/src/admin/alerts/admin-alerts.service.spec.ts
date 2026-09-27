import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Call, fakeSupabase } from '../../moderation/fake-supabase.testspec';
import { SupabaseService } from '../../supabase/supabase.service';
import { AdminAlertsService } from './admin-alerts.service';
import { AdminAlert, buildAlert, fingerprint, RULES, sortAlerts } from './alert-rules';
import { AdminContext } from '../auth/admin-role';

const NOW = Date.parse('2026-09-27T12:00:00Z');
const ago = (ms: number) => new Date(NOW - ms).toISOString();
const MIN = 60_000;
const H = 60 * MIN;
const D = 24 * H;

const has = (call: Call, op: string, ...args: unknown[]) =>
  call.ops.some(([o, a]) => o === op && args.every((v, i) => JSON.stringify(a[i]) === JSON.stringify(v)));
const selected = (call: Call) => String(call.ops.find(([o]) => o === 'select')?.[1][0] ?? '');

interface World {
  failReports?: boolean;
  empty?: boolean;
  /** Config the service reads. Defaults to real money: MPESA_ENV=production, no cutover date. */
  env?: Record<string, string>;
  /** The split's provider share is recorded as paid in the settlements ledger. */
  paidSplit?: boolean;
  /** Rows in admin_alert_reviews, newest first. */
  reviews?: Array<Record<string, unknown>>;
  failReviews?: boolean;
  /** Listings the title lookup no longer finds (transactions.post_id has no foreign key). */
  orphanPosts?: string[];
}

/** One marketplace with exactly one instance of every condition, plus near-misses. */
function world(opts: World = {}) {
  const tx = (id: string, status: string, escrow: string | null, extra: Record<string, unknown> = {}) => ({
    id,
    post_id: `post-${id}`,
    amount: 1000,
    total_paid: 1000,
    status,
    failure_reason: null,
    created_at: ago(3 * D),
    escrow: escrow ? [{ status: escrow, created_at: ago(3 * D), released_at: null }] : [],
    ...extra,
  });

  const transactions = opts.empty ? [] : [
    tx('failed-payout', 'paid', 'locked', { failure_reason: 'Insufficient float', total_paid: 2000 }),
    tx('stuck', 'payout_pending', 'payout_pending'),
    tx('fresh-payout', 'payout_pending', 'payout_pending'),
    tx('phantom', 'failed', 'locked'),
    tx('mismatch', 'paid', null),
    tx('pending-old', 'pending', null, { created_at: ago(3 * H) }),
    tx('pending-new', 'pending', null, { created_at: ago(10 * MIN) }),
    tx('held-long', 'paid', 'locked', { created_at: ago(20 * D) }),
    tx('held-long-progressed', 'paid', 'locked', { created_at: ago(20 * D) }),
    tx('held-short', 'paid', 'locked', { created_at: ago(2 * D) }),
    tx('split', 'refunded', 'refunded'),
    tx('frozen', 'paid', 'locked'),
    tx('done', 'released', 'released'),
    // Its dispute was resolved, but the money was never moved out of "disputed".
    tx('stale-freeze', 'disputed', 'disputed', { created_at: ago(4 * D) }),
  ];

  const disputes = opts.empty ? [] : [
    { id: 'd-escalated', post_id: 'post-frozen', transaction_id: 'frozen', status: 'escalated', reason: 'Work not done',
      created_at: ago(5 * D), first_response_at: ago(4 * D), escalated_at: ago(2 * D), posts: { title: 'Job frozen' }, transactions: { total_paid: 1000 } },
    { id: 'd-split', post_id: 'post-split', transaction_id: 'split', status: 'resolved_partial', reason: 'Half done',
      created_at: ago(9 * D), first_response_at: ago(9 * D), escalated_at: null, posts: { title: 'Job split' }, transactions: { total_paid: 1000 } },
    { id: 'd-stale', post_id: 'post-stale-freeze', transaction_id: 'stale-freeze', status: 'resolved', reason: 'Old case',
      created_at: ago(30 * D), first_response_at: ago(30 * D), escalated_at: null, posts: { title: 'Job stale' }, transactions: { total_paid: 270 } },
    { id: 'd-new', post_id: 'post-x', transaction_id: null, status: 'open', reason: 'Provider no-show',
      created_at: ago(5 * H), first_response_at: null, escalated_at: null, posts: { title: 'Job x' }, transactions: null },
    { id: 'd-waiting-client', post_id: 'post-y', transaction_id: null, status: 'awaiting_client_evidence', reason: 'Photos needed',
      created_at: ago(1 * D), first_response_at: ago(20 * H), escalated_at: null, posts: { title: 'Job y' }, transactions: null },
  ];
  const ACTIVE = new Set(['open', 'reviewing', 'under_review', 'escalated', 'awaiting_client_evidence', 'awaiting_provider_evidence', 'awaiting_admin_review']);

  const { supabase, calls } = fakeSupabase((call: Call) => {
    switch (call.table) {
      case 'transactions':
        if (selected(call).includes('escrow(')) return { data: transactions };
        // "was this assigned post ever paid?"
        return { data: opts.empty ? [] : [{ post_id: 'post-assigned-paid' }] };
      case 'disputes':
        if (selected(call).includes('posts(')) return { data: disputes.filter((d) => ACTIVE.has(d.status)) };
        return { data: disputes };
      case 'dispute_decisions':
        return { data: opts.empty ? [] : [{ dispute_id: 'd-split', decision_type: 'PARTIAL_SPLIT', provider_amount: 700, created_at: ago(8 * D) }] };
      case 'payout_audit_events':
        return { data: [
          { transaction_id: 'stuck', event_type: 'payout_sent_to_processor', occurred_at: ago(2 * H) },
          { transaction_id: 'fresh-payout', event_type: 'payout_sent_to_processor', occurred_at: ago(5 * MIN) },
          { transaction_id: 'failed-payout', event_type: 'payout_failed', occurred_at: ago(1 * D) },
        ] };
      case 'job_completions':
        if (has(call, 'eq', 'status', 'pending_approval')) {
          return { data: opts.empty ? [] : [{ id: 'c-overdue', post_id: 'post-roof', created_at: ago(4 * D) }] };
        }
        return { data: [{ post_id: 'post-held-long-progressed' }] };
      case 'posts':
        if (has(call, 'eq', 'status', 'assigned')) {
          return { data: opts.empty ? [] : [
            { id: 'post-assigned', title: 'Paint my wall', created_at: ago(10 * D) },
            { id: 'post-assigned-paid', title: 'Paid job', created_at: ago(10 * D) },
            { id: 'post-assigned-recent', title: 'Just hired', created_at: ago(10 * D) },
            { id: 'post-assigned-ancient', title: 'Long dead', created_at: ago(200 * D) },
          ] };
        }
        if (has(call, 'eq', 'type', 'request')) {
          return { data: opts.empty ? [] : [
            { id: 'r-urgent', title: 'Burst pipe', urgency: 'urgent', is_urgent: true, category: 'Plumbing', location: 'Nyali', created_at: ago(3 * H) },
            { id: 'r-urgent-new', title: 'Leak', urgency: 'urgent', is_urgent: true, category: 'Plumbing', location: 'Nyali', created_at: ago(1 * H) },
            { id: 'r-flexible', title: 'Paint fence', urgency: 'flexible', is_urgent: false, category: 'Painting', location: 'Bamburi', created_at: ago(2 * D) },
            { id: 'r-flexible-new', title: 'Tiling', urgency: 'flexible', is_urgent: false, category: 'Tiling', location: 'Kisauni', created_at: ago(3 * H) },
            { id: 'r-answered', title: 'Wiring', urgency: 'soon', is_urgent: false, category: 'Electrical', location: 'Nyali', created_at: ago(2 * D) },
          ] };
        }
        {
          // Title lookup by id — how every money alert names its listing.
          const inIds = call.ops.find(([o, a]) => o === 'in' && a[0] === 'id')?.[1][1] as string[] | undefined;
          return { data: (inIds ?? [])
            .filter((id) => !opts.orphanPosts?.includes(id))
            .map((id) => ({ id, title: id === 'post-roof' ? 'Fix my roof' : `Job ${id.replace('post-', '')}` })) };
        }
      case 'system_events':
        return { data: [
          { entity_id: 'post-assigned', created_at: ago(5 * D) },
          { entity_id: 'post-assigned-recent', created_at: ago(1 * D) },
          { entity_id: 'post-assigned-ancient', created_at: ago(150 * D) },
        ] };
      case 'applications':
        return { data: [{ post_id: 'r-answered' }] };
      case 'user_reports':
        if (opts.failReports) return { error: { message: 'column user_reports.severity does not exist' } };
        return { data: opts.empty ? [] : [
          { id: 'rep-threat', reason: 'threats', severity: 'high', status: 'new', assigned_admin_id: null, target_type: 'user', created_at: ago(2 * H) },
          { id: 'rep-spam', reason: 'spam', severity: 'low', status: 'new', assigned_admin_id: null, target_type: 'post', created_at: ago(1 * H) },
          { id: 'rep-claimed', reason: 'scam_or_fraud', severity: 'critical', status: 'under_review', assigned_admin_id: 'a-1', target_type: 'user', created_at: ago(1 * D) },
        ] };
      case 'settlements':
        return { data: opts.paidSplit ? [{ transaction_id: 'split' }] : [] };
      case 'admin_alert_reviews':
        if (call.ops.some(([o]) => o === 'insert')) return { data: null };
        if (opts.failReviews) return { error: { message: 'relation "admin_alert_reviews" does not exist' } };
        return { data: opts.reviews ?? [] };
      case 'promotion_campaigns':
        return { data: opts.empty ? [] : [{ id: 'camp-1', post_title: 'Home cleaning', package_name: 'Boost', price_kes: 500, created_at: ago(1 * D), updated_at: ago(20 * H) }] };
      default:
        return { data: [] };
    }
  });
  const env = opts.env ?? { MPESA_ENV: 'production' };
  const config = { get: (key: string, fallback?: unknown) => env[key] ?? fallback } as unknown as ConfigService;
  const service = new AdminAlertsService(supabase as unknown as SupabaseService, config);
  return { service, calls };
}

const byId = (alerts: AdminAlert[]) => new Map(alerts.map((a) => [a.id, a]));
const ids = (a: AdminAlert | undefined) => a?.items.map((i) => i.id) ?? [];

beforeEach(() => {
  jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
});
afterEach(() => jest.restoreAllMocks());

describe('AdminAlertsService — financial & escrow (through deriveSettlementState)', () => {
  it('a failed payout is HIGH, with the amount owed and M-Pesa\'s reason', async () => {
    const a = byId((await world().service.compute(NOW)).alerts).get('payout_failed');
    expect(a?.priority).toBe('high');
    expect(ids(a)).toEqual(['failed-payout']);
    expect(a?.amount_kes).toBe(2000);
    expect(a?.items[0].detail).toContain('Insufficient float');
    expect(a?.items[0].at).toBe(ago(1 * D)); // when it failed, from the audit trail
    expect(a?.items[0].label).toBe('Job failed-payout'); // named via the id lookup
  });

  it('never embeds posts in the transactions query — live has no foreign key for it', async () => {
    const { service, calls } = world();
    await service.compute(NOW);
    const txSelects = calls.filter((c) => c.table === 'transactions').map(selected);
    expect(txSelects.length).toBeGreaterThan(0);
    for (const sel of txSelects) expect(sel).not.toContain('posts(');
  });

  it('a payout with no result for 30+ minutes is stuck; a fresh one is not', async () => {
    const a = byId((await world().service.compute(NOW)).alerts).get('payout_stuck');
    expect(a?.priority).toBe('high');
    expect(ids(a)).toEqual(['stuck']);
  });

  it('a split decision leaves the provider\'s share owed — HIGH, for the provider amount', async () => {
    const a = byId((await world().service.compute(NOW)).alerts).get('provider_owed');
    expect(a?.priority).toBe('high');
    expect(ids(a)).toEqual(['split']);
    expect(a?.amount_kes).toBe(700);
  });

  it('records that disagree are HIGH when money arrived, MEDIUM when none did', async () => {
    const alerts = byId((await world().service.compute(NOW)).alerts);
    expect(ids(alerts.get('money_mismatch')).sort()).toEqual(['mismatch', 'stale-freeze']);
    expect(alerts.get('money_mismatch')?.priority).toBe('high');
    expect(ids(alerts.get('phantom_escrow'))).toEqual(['phantom']);
    expect(alerts.get('phantom_escrow')?.priority).toBe('medium');
    expect(alerts.get('phantom_escrow')?.amount_kes).toBeNull();
    // each item says WHICH impossibility it is
    const detailOf = (id: string) => alerts.get('money_mismatch')?.items.find((i) => i.id === id)?.detail;
    expect(detailOf('mismatch')).toBe('Payment paid, but there is no escrow record');
  });

  it('money frozen as disputed with no dispute open is named as exactly that', async () => {
    const { service } = world();
    const res = await service.compute(NOW);
    // "frozen" has a live dispute, so it is not an alert; a resolved-but-still-frozen one is.
    expect(res.alerts.flatMap((a) => a.items.map((i) => i.id))).not.toContain('frozen');
    const item = byId(res.alerts).get('money_mismatch')?.items.find((i) => i.id === 'stale-freeze');
    expect(item?.detail).toBe('Frozen as disputed, but no dispute is open');
  });

  it('a payment still pending after an hour is unconfirmed; a ten-minute one is not', async () => {
    const a = byId((await world().service.compute(NOW)).alerts).get('payment_unconfirmed');
    expect(ids(a)).toEqual(['pending-old']);
  });

  it('a job paid two weeks ago with no completion request is stalled; one with progress is not', async () => {
    const a = byId((await world().service.compute(NOW)).alerts).get('paid_stalled');
    expect(a?.category).toBe('marketplace');
    expect(ids(a)).toEqual(['held-long']);
  });

  it('a disputed or settled payment raises nothing here', async () => {
    const all = (await world().service.compute(NOW)).alerts.flatMap((a) => a.items.map((i) => i.id));
    expect(all).not.toContain('frozen');
    expect(all).not.toContain('done');
    expect(all).not.toContain('held-short');
  });
});

describe('AdminAlertsService — disputes', () => {
  it('escalated is HIGH; a new unanswered case is MEDIUM; one waiting on a party is nothing', async () => {
    const alerts = byId((await world().service.compute(NOW)).alerts);
    expect(ids(alerts.get('dispute_escalated'))).toEqual(['d-escalated']);
    expect(alerts.get('dispute_escalated')?.priority).toBe('high');
    expect(alerts.get('dispute_escalated')?.items[0].href).toBe('/dashboard/disputes/d-escalated');
    expect(ids(alerts.get('dispute_awaiting_admin'))).toEqual(['d-new']);
  });
});

describe('AdminAlertsService — trust & safety', () => {
  it('an unassigned serious report is HIGH; other new reports are MEDIUM; claimed ones are nobody\'s alert', async () => {
    const alerts = byId((await world().service.compute(NOW)).alerts);
    expect(ids(alerts.get('reports_urgent'))).toEqual(['rep-threat']);
    expect(alerts.get('reports_urgent')?.priority).toBe('high');
    expect(ids(alerts.get('reports_untriaged'))).toEqual(['rep-spam']);
  });

  it('when the reports table is not migrated yet, that check is UNAVAILABLE — not "all clear" — and the rest still answer', async () => {
    const res = await world({ failReports: true }).service.compute(NOW);
    expect(res.unavailable.map((u) => u.source)).toEqual(['reports']);
    const alerts = byId(res.alerts);
    expect(alerts.has('reports_urgent')).toBe(false);
    expect(alerts.has('payout_failed')).toBe(true);
    expect(JSON.stringify(res.unavailable)).not.toContain('severity'); // no schema detail leaks to the UI
  });
});

describe('AdminAlertsService — marketplace health', () => {
  it('finished work waiting on the client for 72h+ is MEDIUM, named by its listing', async () => {
    const a = byId((await world().service.compute(NOW)).alerts).get('completion_overdue');
    expect(a?.priority).toBe('medium');
    expect(a?.items[0].label).toBe('Fix my roof');
  });

  it('hired-but-never-paid is LOW, timed from the selection event, ignores paid jobs and dead ones', async () => {
    const a = byId((await world().service.compute(NOW)).alerts).get('assigned_unpaid');
    expect(a?.priority).toBe('low');
    // not the paid one, not the one hired yesterday, not the one hired 150 days ago
    expect(ids(a)).toEqual(['post-assigned']);
  });

  it('urgent requests unanswered for 2h are MEDIUM; others after 24h are LOW; answered ones never appear', async () => {
    const alerts = byId((await world().service.compute(NOW)).alerts);
    expect(ids(alerts.get('urgent_unanswered'))).toEqual(['r-urgent']);
    expect(alerts.get('urgent_unanswered')?.priority).toBe('medium');
    expect(ids(alerts.get('requests_unanswered'))).toEqual(['r-flexible']);
    expect(alerts.get('requests_unanswered')?.priority).toBe('low');
  });

  it('a paid promotion awaiting review is MEDIUM and links to the campaign', async () => {
    const a = byId((await world().service.compute(NOW)).alerts).get('promotion_review');
    expect(a?.items[0].href).toBe('/dashboard/promotion/camp-1');
    expect(a?.amount_kes).toBe(500);
  });
});

describe('AdminAlertsService — each item opens the page where the admin can act', () => {
  // The dashboard cannot message users outside a dispute, so "act" on a
  // marketplace alert means phoning someone: the request's own page carries
  // both people's numbers and, when it is unanswered, who could take it.
  it('request and job alerts link each item to that request\'s own page, not to a list', async () => {
    const alerts = byId((await world().service.compute(NOW)).alerts);
    const hrefOf = (id: string) => alerts.get(id as AdminAlert['id'])?.items[0].href;
    expect(hrefOf('urgent_unanswered')).toBe('/dashboard/marketplace/requests/r-urgent');
    expect(hrefOf('requests_unanswered')).toBe('/dashboard/marketplace/requests/r-flexible');
    expect(hrefOf('completion_overdue')).toBe('/dashboard/marketplace/requests/post-roof');
    expect(hrefOf('assigned_unpaid')).toBe('/dashboard/marketplace/requests/post-assigned');
  });

  it('a failed payout and a stalled job open the job, where the provider\'s phone is', async () => {
    const alerts = byId((await world().service.compute(NOW)).alerts);
    expect(alerts.get('payout_failed')?.items[0].href).toBe('/dashboard/marketplace/requests/post-failed-payout');
    expect(alerts.get('paid_stalled')?.items[0].href).toBe('/dashboard/marketplace/requests/post-held-long');
    // A stuck payout stays on the escrow page — "Check with M-Pesa" is there.
    expect(alerts.get('payout_stuck')?.items[0].href).toBe('/dashboard/payments/escrow');
  });

  it('a payment whose listing is gone falls back to the escrow page instead of a page that 404s', async () => {
    const alerts = byId((await world({ orphanPosts: ['post-held-long'] }).service.compute(NOW)).alerts);
    const it0 = alerts.get('paid_stalled')?.items[0];
    expect(it0?.label).toMatch(/^Listing not found/);
    expect(it0?.href).toBe('/dashboard/payments/escrow');
  });

  it('test money keeps the same links, so the quiet list is just as actionable', async () => {
    const a = byId((await world({ env: { MPESA_ENV: 'sandbox' } }).service.compute(NOW)).alerts).get('sandbox_money');
    // The alert carries its first few records; held-long is among them.
    expect(a?.items.find((i) => i.id === 'held-long')?.href).toBe('/dashboard/marketplace/requests/post-held-long');
    for (const i of a?.items ?? []) expect(i.href).not.toBe('/dashboard/marketplace/active-jobs');
  });

  it('item ids — and so review fingerprints — did not change with the links', async () => {
    const alerts = byId((await world().service.compute(NOW)).alerts);
    expect(ids(alerts.get('urgent_unanswered'))).toEqual(['r-urgent']);
    expect(ids(alerts.get('completion_overdue'))).toEqual(['c-overdue']);
    expect(ids(alerts.get('paid_stalled'))).toEqual(['held-long']);
  });
});

describe('AdminAlertsService — the list as a whole', () => {
  it('orders high before medium before low, money before safety before health', async () => {
    const alerts = (await world().service.compute(NOW)).alerts;
    const rank = { high: 0, medium: 1, low: 2 } as const;
    for (let i = 1; i < alerts.length; i++) {
      expect(rank[alerts[i - 1].priority]).toBeLessThanOrEqual(rank[alerts[i].priority]);
    }
    expect(alerts[0].category).toBe('financial');
  });

  it('a quiet marketplace yields no alerts and no unavailable sources', async () => {
    const res = await world({ empty: true }).service.compute(NOW);
    expect(res.alerts).toEqual([]);
    expect(res.unavailable).toEqual([]);
  });

  it('it only reads', async () => {
    const { service, calls } = world();
    await service.compute(NOW);
    const writes = calls.filter((c) => c.ops.some(([o]) => ['insert', 'update', 'upsert', 'delete'].includes(o)) || c.rpc);
    expect(writes).toEqual([]);
  });

  it('admins polling together share one computation for a few seconds', async () => {
    const { service, calls } = world();
    await Promise.all([service.list(), service.list()]);
    const first = calls.length;
    await service.list();
    expect(calls.length).toBe(first);
  });
});

describe('AdminAlertsService — real money vs test money (fix 2)', () => {
  const MONEY = ['payout_failed', 'payout_stuck', 'provider_owed', 'money_mismatch', 'phantom_escrow', 'payment_unconfirmed', 'paid_stalled'];

  it('while M-Pesa is on the Daraja sandbox, every money state is ONE low alert — nothing high, nothing on the badge', async () => {
    const res = await world({ env: { MPESA_ENV: 'sandbox' } }).service.compute(NOW);
    const alerts = byId(res.alerts);
    for (const id of MONEY) expect(alerts.has(id as never)).toBe(false);
    const test = alerts.get('sandbox_money');
    expect(test?.priority).toBe('low');
    expect(test?.count).toBe(8); // failed, stuck, split, 2× mismatch, phantom, pending-old, held-long
    expect(test?.detail).toContain('Daraja sandbox');
    // Each line names the state it was left in (the panel carries the first five).
    const labels = /^(Payout failed|Payout with no M-Pesa result|Split share not recorded as paid|Records disagree|Hold with no payment|Payment never confirmed|Paid, no progress) — /;
    expect(test?.items.length).toBe(5);
    for (const i of test?.items ?? []) expect(i.detail).toMatch(labels);
    // What is still HIGH is not money: a dispute and a safety report.
    expect(res.alerts.filter((a) => a.priority === 'high').map((a) => a.id).sort()).toEqual(['dispute_escalated', 'reports_urgent']);
  });

  it('with no MPESA_ENV at all it assumes the sandbox — the Daraja client defaults the same way', async () => {
    const res = await world({ env: {} }).service.compute(NOW);
    expect(byId(res.alerts).has('sandbox_money')).toBe(true);
    expect(byId(res.alerts).has('payout_failed')).toBe(false);
  });

  it('after the cutover, payments before MPESA_PRODUCTION_SINCE stay test money and later ones are real', async () => {
    const res = await world({ env: { MPESA_ENV: 'production', MPESA_PRODUCTION_SINCE: ago(1 * D) } }).service.compute(NOW);
    const alerts = byId(res.alerts);
    expect(ids(alerts.get('payment_unconfirmed'))).toEqual(['pending-old']); // 3 hours old → real
    expect(alerts.has('payout_failed')).toBe(false); // 3 days old → test
    expect(alerts.get('sandbox_money')?.detail).toContain('Made before M-Pesa went live');
  });
});

describe('AdminAlertsService — owed shares and where they are repaired (fix 4)', () => {
  it('a split share recorded as paid in the settlements ledger is no longer owed', async () => {
    expect(byId((await world({ paidSplit: true }).service.compute(NOW)).alerts).has('provider_owed')).toBe(false);
  });

  it('owed shares and frozen money link to the dispute where they are repaired; money with no dispute links to escrow', async () => {
    const alerts = byId((await world().service.compute(NOW)).alerts);
    expect(alerts.get('provider_owed')?.items[0].href).toBe('/dashboard/disputes/d-split');
    const hrefOf = (id: string) => alerts.get('money_mismatch')?.items.find((i) => i.id === id)?.href;
    expect(hrefOf('stale-freeze')).toBe('/dashboard/disputes/d-stale');
    expect(hrefOf('mismatch')).toBe('/dashboard/payments/escrow');
  });
});

describe('AdminAlertsService — shared reviews (fixes 1 and 3)', () => {
  const admin: AdminContext = { id: 'a-senior', email: 'senior@help24.test', name: 'Senior', role: 'senior_admin' };
  const stuckFp = fingerprint(['stuck']);
  const reviewed = (fp: string, action = 'reviewed') => ({
    alert_id: 'payout_stuck', fingerprint: fp, action, note: 'Sandbox payouts — asked M-Pesa', admin_email: 'senior@help24.test',
    admin_role: 'senior_admin', created_at: ago(1 * H),
  });

  it('a review of the exact records quiets the alert for everyone; a different set, or a reopen, raises it again', async () => {
    const quiet = byId((await world({ reviews: [reviewed(stuckFp)] }).service.compute(NOW)).alerts).get('payout_stuck');
    expect(quiet?.review).toMatchObject({ admin_email: 'senior@help24.test', note: 'Sandbox payouts — asked M-Pesa' });
    const changed = byId((await world({ reviews: [reviewed('0000000000000000')] }).service.compute(NOW)).alerts).get('payout_stuck');
    expect(changed?.review).toBeNull();
    const reopened = byId((await world({ reviews: [reviewed(stuckFp, 'reopened'), reviewed(stuckFp)] }).service.compute(NOW)).alerts).get('payout_stuck');
    expect(reopened?.review).toBeNull(); // newest row wins
  });

  it('reviews that cannot be read leave every alert counted — "unreviewed" is the safe reading', async () => {
    const res = await world({ failReviews: true }).service.compute(NOW);
    expect(res.unavailable.map((u) => u.source)).toEqual(['reviews']);
    expect(res.alerts.every((a) => a.review === null)).toBe(true);
  });

  it('reviewing needs a reason and the fingerprint of the alert as it is NOW', async () => {
    const { service } = world();
    await expect(service.review(admin, 'nope_alert', { action: 'reviewed', fingerprint: stuckFp, note: 'reason here' })).rejects.toMatchObject({ status: 404 });
    await expect(service.review(admin, 'payout_stuck', { action: 'reviewed', fingerprint: stuckFp, note: 'ok' })).rejects.toMatchObject({ status: 400 });
    await expect(service.review(admin, 'payout_stuck', { action: 'reviewed', fingerprint: '0000000000000000', note: 'Looked at it' }))
      .rejects.toMatchObject({ status: 409 });
    await expect(service.review(admin, 'payout_stuck', { action: 'reopened', fingerprint: stuckFp })).rejects.toMatchObject({ status: 409 });
  });

  it('a valid review is written with who, in what role, and why — and the shared result is recomputed', async () => {
    const { service, calls } = world();
    // review() judges the alert as it is NOW (real time), so take the fingerprint from there.
    const fp = (await service.list()).alerts.find((a) => a.id === 'payout_stuck')!.fingerprint;
    const before = calls.length;
    await service.review(admin, 'payout_stuck', { action: 'reviewed', fingerprint: fp, note: 'Sandbox payouts — asked M-Pesa' });
    const insert = calls.find((c) => c.table === 'admin_alert_reviews' && c.ops.some(([o]) => o === 'insert'));
    expect(insert?.ops.find(([o]) => o === 'insert')?.[1][0]).toMatchObject({
      alert_id: 'payout_stuck', fingerprint: fp, action: 'reviewed', admin_id: 'a-senior', admin_email: 'senior@help24.test',
      admin_role: 'senior_admin', note: 'Sandbox payouts — asked M-Pesa',
    });
    expect(calls.length).toBeGreaterThan(before + 20); // recomputed, not served from the cache
  });
});

describe('alert-rules', () => {
  it('a fingerprint ignores order and changes when the set of records changes', () => {
    expect(fingerprint(['a', 'b'])).toBe(fingerprint(['b', 'a']));
    expect(fingerprint(['a', 'b'])).not.toBe(fingerprint(['a', 'b', 'c']));
  });

  it('an alert with nothing behind it does not exist', () => {
    expect(buildAlert('payout_failed', [], () => 'x')).toBeNull();
  });

  it('every rule has a priority, a category, a link into the dashboard and an action', () => {
    for (const [id, rule] of Object.entries(RULES)) {
      expect(['high', 'medium', 'low']).toContain(rule.priority);
      expect(['financial', 'trust_safety', 'marketplace']).toContain(rule.category);
      expect(rule.href.startsWith('/dashboard/')).toBe(true);
      expect(rule.action.length).toBeGreaterThan(3);
      expect(rule.title(1)).not.toEqual(rule.title(2)); // singular and plural read differently
      expect(id).toMatch(/^[a-z_]+$/);
    }
  });

  it('no action promises a control the dashboard does not have (audit of 2026-09-27)', () => {
    // Each of these named something no page could do: there is no provider
    // search, no way to message a user outside a dispute, no payout retry and
    // no general reconcile. They are what an admin can do now: phone someone
    // from the request's page, or investigate.
    const retired = ['Find a provider', 'Recruit supply', 'Nudge the client', 'Check in with both parties',
      'Follow up with the client', 'Retry or pay out manually', 'Reconcile the records'];
    const actions = Object.values(RULES).map((r) => r.action);
    for (const label of retired) expect(actions).not.toContain(label);
    expect(RULES.urgent_unanswered.action).toBe('Call a matching provider');
    expect(RULES.paid_stalled.action).toBe('Call both parties');
  });

  it('only money, disputes and safety are ever HIGH', () => {
    const high = Object.entries(RULES).filter(([, r]) => r.priority === 'high').map(([id]) => id);
    expect(high.sort()).toEqual(['dispute_escalated', 'money_mismatch', 'payout_failed', 'payout_stuck', 'provider_owed', 'reports_urgent']);
  });

  it('sortAlerts keeps the oldest first within a tier', () => {
    const mk = (id: 'payout_failed' | 'payout_stuck', at: string) => buildAlert(id, [{ id, label: id, at }], () => '')!;
    const sorted = sortAlerts([mk('payout_stuck', ago(1 * H)), mk('payout_failed', ago(5 * H))]);
    expect(sorted.map((a) => a.id)).toEqual(['payout_failed', 'payout_stuck']);
  });
});
