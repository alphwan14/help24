import { Logger } from '@nestjs/common';
import { Call, fakeSupabase } from '../../moderation/fake-supabase.testspec';
import { SupabaseService } from '../../supabase/supabase.service';
import { AdminAlertsService } from './admin-alerts.service';
import { AdminAlert, buildAlert, fingerprint, RULES, sortAlerts } from './alert-rules';

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
          return { data: (inIds ?? []).map((id) => ({ id, title: id === 'post-roof' ? 'Fix my roof' : `Job ${id.replace('post-', '')}` })) };
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
      case 'promotion_campaigns':
        return { data: opts.empty ? [] : [{ id: 'camp-1', post_title: 'Home cleaning', package_name: 'Boost', price_kes: 500, created_at: ago(1 * D), updated_at: ago(20 * H) }] };
      default:
        return { data: [] };
    }
  });
  const service = new AdminAlertsService(supabase as unknown as SupabaseService);
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
