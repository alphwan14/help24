import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../../supabase/supabase.service';
import { deriveSettlementState } from '../../jobs/settlement-state';
import {
  AdminAlert,
  AlertItem,
  THRESHOLDS,
  ageOf,
  buildAlert,
  kes,
  sortAlerts,
  truncate,
} from './alert-rules';

type Row = Record<string, any>;
type Result<T> = { data: T | null; error: { message: string } | null };

export interface AlertsResponse {
  generated_at: string;
  alerts: AdminAlert[];
  /** Sources that could not be read. Never folded into "all clear". */
  unavailable: Array<{ source: string; reason: string }>;
}

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** Money actually arrived from the client. */
const RECEIVED = new Set(['paid', 'payout_pending', 'released', 'refunded', 'disputed']);
const ACTIVE_DISPUTE = [
  'open',
  'reviewing',
  'under_review',
  'escalated',
  'awaiting_client_evidence',
  'awaiting_provider_evidence',
  'awaiting_admin_review',
];
const OPEN_REPORT = ['new', 'under_review', 'action_required'];

/**
 * Derives the admin alert list from live records. Read-only: every query here
 * is a bounded SELECT through the service client, and nothing is written.
 *
 * Each source is isolated. A source that fails (a table that is not migrated
 * yet, a timeout) is reported under `unavailable` and the rest still answer —
 * one broken query must not make the panel claim that nothing needs attention.
 */
@Injectable()
export class AdminAlertsService {
  private readonly logger = new Logger(AdminAlertsService.name);

  /** Several admins polling one backend share one computation. */
  static readonly CACHE_MS = 20_000;
  private cache: { at: number; value: AlertsResponse } | null = null;
  private inFlight: Promise<AlertsResponse> | null = null;

  constructor(private readonly supabase: SupabaseService) {}

  private get db() {
    return this.supabase.client;
  }

  list(): Promise<AlertsResponse> {
    const now = Date.now();
    if (this.cache && now - this.cache.at < AdminAlertsService.CACHE_MS) return Promise.resolve(this.cache.value);
    this.inFlight ??= this.compute(now)
      .then((value) => {
        this.cache = { at: Date.now(), value };
        return value;
      })
      .finally(() => {
        this.inFlight = null;
      });
    return this.inFlight;
  }

  async compute(now = Date.now()): Promise<AlertsResponse> {
    const unavailable: AlertsResponse['unavailable'] = [];
    const isolate = async (source: string, fn: () => Promise<Array<AdminAlert | null>>) => {
      try {
        return await fn();
      } catch (e) {
        const reason = e instanceof Error ? e.message : String(e);
        this.logger.warn(`[ALERTS] ${source} unavailable: ${reason}`);
        unavailable.push({ source, reason: 'This check could not run.' });
        return [];
      }
    };

    const groups = await Promise.all([
      isolate('payments', () => this.moneyAlerts(now)),
      isolate('disputes', () => this.disputeAlerts()),
      isolate('reports', () => this.reportAlerts()),
      isolate('jobs', () => this.jobAlerts(now)),
      isolate('requests', () => this.requestAlerts(now)),
      isolate('promotions', () => this.promotionAlerts()),
    ]);

    const alerts = sortAlerts(groups.flat().filter((a): a is AdminAlert => a !== null));
    return { generated_at: new Date(now).toISOString(), alerts, unavailable };
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Financial & escrow — through the ONE canonical settlement derivation
  // ═══════════════════════════════════════════════════════════════════════════

  private async moneyAlerts(now: number): Promise<Array<AdminAlert | null>> {
    const [{ data: txData }, { data: disputeData }, { data: decisionData }] = await Promise.all([
      must<Row[]>(this.db.from('transactions')
        // No posts(...) embed: live transactions.post_id has no foreign key to
        // posts, so PostgREST cannot join it. Titles are looked up by id below.
        .select('id, post_id, amount, total_paid, status, failure_reason, created_at, escrow(status, created_at, released_at)')
        .in('status', ['pending', 'paid', 'payout_pending', 'released', 'refunded', 'disputed', 'failed'])
        .order('created_at', { ascending: false })
        .limit(2000)),
      must<Row[]>(this.db.from('disputes').select('id, post_id, transaction_id, status').limit(2000)),
      must<Row[]>(this.db.from('dispute_decisions')
        .select('dispute_id, decision_type, provider_amount, created_at')
        .neq('decision_type', 'ESCALATE')
        .order('created_at', { ascending: false })
        .limit(2000)),
    ]);
    const txs = txData ?? [];
    const disputes = disputeData ?? [];

    // Which transactions a live dispute is freezing. A dispute names its
    // transaction; one that does not freezes its listing's latest payment.
    const latestTxByPost = new Map<string, string>();
    for (const tx of txs) if (!latestTxByPost.has(tx.post_id)) latestTxByPost.set(tx.post_id, tx.id);
    const frozen = new Set<string>();
    for (const d of disputes) {
      if (!ACTIVE_DISPUTE.includes(d.status)) continue;
      const txId = d.transaction_id ?? latestTxByPost.get(d.post_id);
      if (txId) frozen.add(txId);
    }

    // The latest money decision per transaction (a split is what leaves a
    // provider's share owed).
    const disputeTx = new Map<string, string>();
    for (const d of disputes) {
      const txId = d.transaction_id ?? latestTxByPost.get(d.post_id);
      if (txId) disputeTx.set(d.id, txId);
    }
    const decision = new Map<string, Row>();
    for (const dec of decisionData ?? []) {
      const txId = disputeTx.get(dec.dispute_id);
      if (txId && !decision.has(txId)) decision.set(txId, dec);
    }

    const buckets: Record<string, Array<{ tx: Row; escrow: Row | null }>> = {
      failed: [], processing: [], owed: [], mismatch: [], phantom: [], unconfirmed: [], held: [],
    };
    for (const tx of txs) {
      const escrow = first(tx.escrow);
      const d = decision.get(tx.id);
      const state = deriveSettlementState({
        txStatus: tx.status ?? null,
        escrowStatus: escrow?.status ?? null,
        failureReason: tx.failure_reason ?? null,
        activeDispute: frozen.has(tx.id),
        latestDecisionType: d?.decision_type ?? null,
        amount: tx.amount ?? null,
        fee: null,
        totalPaid: tx.total_paid ?? null,
        providerAmount: d?.provider_amount ?? null,
        clientRefund: null,
        paidAt: null,
        releasedAt: escrow?.released_at ?? null,
        disputedAt: null,
        resolvedAt: null,
      }).state;

      const entry = { tx, escrow };
      if (state === 'settlement_failed') buckets.failed.push(entry);
      else if (state === 'payout_processing') buckets.processing.push(entry);
      else if (state === 'split_settled') buckets.owed.push(entry);
      else if (state === 'inconsistent') (RECEIVED.has(tx.status) ? buckets.mismatch : buckets.phantom).push(entry);
      else if (state === 'awaiting_payment' && tx.status === 'pending' && age(tx.created_at, now) >= THRESHOLDS.paymentUnconfirmedMinutes * MINUTE) {
        buckets.unconfirmed.push(entry);
      } else if (state === 'in_escrow' && age(tx.created_at, now) >= THRESHOLDS.paidStalledDays * DAY) {
        buckets.held.push(entry);
      }
    }

    // When each payout was handed to M-Pesa, and when it failed — the audit
    // trail knows; the transaction row does not.
    const audited = [...buckets.processing, ...buckets.failed].map((e) => e.tx.id as string);
    const sentAt = new Map<string, string>();
    const failedAt = new Map<string, string>();
    if (audited.length) {
      const { data: events } = await must<Row[]>(this.db.from('payout_audit_events')
        .select('transaction_id, event_type, occurred_at')
        .in('transaction_id', audited)
        .in('event_type', ['payout_sent_to_processor', 'payout_failed'])
        .order('occurred_at', { ascending: false })
        .limit(1000));
      for (const ev of events ?? []) {
        const target = ev.event_type === 'payout_failed' ? failedAt : sentAt;
        if (!target.has(ev.transaction_id)) target.set(ev.transaction_id, ev.occurred_at);
      }
    }

    // A paid job counts as stalled only if no completion was ever requested.
    let stalled = buckets.held;
    if (stalled.length) {
      const { data: completions } = await must<Row[]>(this.db.from('job_completions')
        .select('post_id')
        .in('post_id', unique(stalled.map((e) => e.tx.post_id)))
        .limit(2000));
      const progressed = new Set((completions ?? []).map((c) => c.post_id));
      stalled = stalled.filter((e) => !progressed.has(e.tx.post_id));
    }

    const flagged = [...buckets.failed, ...buckets.processing, ...buckets.owed, ...buckets.mismatch,
      ...buckets.phantom, ...buckets.unconfirmed, ...stalled];
    const titles = await this.titles(flagged.map((e) => e.tx.post_id));

    // `amount` omitted → the payment's own total; an explicit null → no money
    // involved (a hold with no payment behind it must not claim one).
    const item = (e: { tx: Row; escrow: Row | null }, at: string | null, detail: string, amount?: number | null): AlertItem => ({
      id: e.tx.id,
      // transactions.post_id has no foreign key, so it can outlive its listing.
      label: titles.has(e.tx.post_id) ? truncate(titles.get(e.tx.post_id)) : `Listing not found (${String(e.tx.post_id).slice(0, 8)})`,
      detail,
      at,
      amount_kes: amount === undefined ? (e.tx.total_paid ?? e.tx.amount ?? null) : amount,
      href: '/dashboard/payments/escrow',
    });

    const stuck = buckets.processing
      .map((e) => ({ e, since: sentAt.get(e.tx.id) ?? e.tx.created_at }))
      .filter(({ since }) => age(since, now) >= THRESHOLDS.payoutStuckMinutes * MINUTE);

    return [
      buildAlert('payout_failed',
        buckets.failed.map((e) => item(e, failedAt.get(e.tx.id) ?? e.tx.created_at, `M-Pesa said: ${truncate(e.tx.failure_reason, 80)}`)),
        (items) => `${kes(sum(items))} owed to providers. Money is still held in escrow.`),
      buildAlert('payout_stuck',
        stuck.map(({ e, since }) => item(e, since, `Sent to M-Pesa ${ageOf(since, now)} ago, no result since`)),
        (items) => `${kes(sum(items))} in flight. Asking M-Pesa for the result settles it only if it succeeded.`),
      buildAlert('provider_owed',
        buckets.owed.map((e) => {
          const d = decision.get(e.tx.id);
          return item(e, d?.created_at ?? e.tx.created_at, 'Split decided; provider share not paid out', d?.provider_amount ?? null);
        }),
        (items) => `${kes(sum(items))} recorded for providers but never sent.`),
      buildAlert('money_mismatch',
        buckets.mismatch.map((e) => item(e, e.tx.created_at, mismatchReason(e.tx, e.escrow, frozen.has(e.tx.id)))),
        (items) => `${kes(sum(items))} received, in a state the payment workflow cannot produce.`),
      buildAlert('phantom_escrow',
        buckets.phantom.map((e) => item(e, e.escrow?.created_at ?? e.tx.created_at, `Payment ${e.tx.status}, escrow ${e.escrow?.status ?? 'missing'}`, null)),
        () => 'No money was received, but the hold blocks the owner from removing the listing.'),
      buildAlert('payment_unconfirmed',
        buckets.unconfirmed.map((e) => item(e, e.tx.created_at, `STK prompt sent ${ageOf(e.tx.created_at, now)} ago, no result recorded`)),
        () => 'M-Pesa never reported back. If the customer paid, the money is unattributed.'),
      buildAlert('paid_stalled',
        stalled.map((e) => item(e, e.tx.created_at, `Paid ${ageOf(e.tx.created_at, now)} ago, no completion requested`)),
        (items) => `${kes(sum(items))} held with no sign of the work being done.`),
    ];
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Disputes — the SLA sweep escalates at 3 days; escalated is the loud state
  // ═══════════════════════════════════════════════════════════════════════════

  private async disputeAlerts(): Promise<Array<AdminAlert | null>> {
    const { data } = await must<Row[]>(this.db.from('disputes')
      .select('id, status, reason, created_at, first_response_at, escalated_at, posts(title), transactions(total_paid)')
      .in('status', ACTIVE_DISPUTE)
      .limit(500));
    const rows = data ?? [];
    const item = (d: Row, at: string | null): AlertItem => ({
      id: d.id,
      label: truncate(first(d.posts)?.title),
      detail: truncate(d.reason, 90),
      at,
      amount_kes: first(d.transactions)?.total_paid ?? null,
      href: `/dashboard/disputes/${d.id}`,
    });
    const escalated = rows.filter((d) => d.status === 'escalated');
    const waiting = rows.filter((d) => (d.status === 'open' && !d.first_response_at) || d.status === 'awaiting_admin_review');
    return [
      buildAlert('dispute_escalated', escalated.map((d) => item(d, d.escalated_at ?? d.created_at)),
        (items) => `${kes(sum(items))} frozen. Past the 3-day response window or escalated by an admin.`),
      buildAlert('dispute_awaiting_admin', waiting.map((d) => item(d, d.created_at)),
        () => 'New cases nobody has answered yet, or evidence that is back with us.'),
    ];
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Trust & safety — from the reports queue (migration 114)
  // ═══════════════════════════════════════════════════════════════════════════

  private async reportAlerts(): Promise<Array<AdminAlert | null>> {
    const { data } = await must<Row[]>(this.db.from('user_reports')
      .select('id, reason, severity, status, assigned_admin_id, target_type, created_at')
      .in('status', OPEN_REPORT)
      .limit(1000));
    const rows = data ?? [];
    const item = (r: Row): AlertItem => ({
      id: r.id,
      label: `${humanise(r.reason)} — ${targetWord(r.target_type)}`,
      detail: `${humanise(r.severity)} severity · ref ${String(r.id).replace(/-/g, '').slice(0, 8).toUpperCase()}`,
      at: r.created_at,
      href: `/dashboard/trust-safety/reports/${r.id}`,
    });
    const urgent = rows.filter((r) => (r.severity === 'critical' || r.severity === 'high') && !r.assigned_admin_id);
    const urgentIds = new Set(urgent.map((r) => r.id));
    const untriaged = rows.filter((r) => r.status === 'new' && !urgentIds.has(r.id));
    return [
      buildAlert('reports_urgent', urgent.map(item),
        () => 'Threats, scams, illegal or unsafe behaviour, or several people reporting one account.'),
      buildAlert('reports_untriaged', untriaged.map(item), () => 'Nobody has looked at these yet.'),
    ];
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Jobs that stopped moving
  // ═══════════════════════════════════════════════════════════════════════════

  private async jobAlerts(now: number): Promise<Array<AdminAlert | null>> {
    const overdueCutoff = new Date(now - THRESHOLDS.completionOverdueHours * HOUR).toISOString();
    const [{ data: completions }, { data: assigned }] = await Promise.all([
      must<Row[]>(this.db.from('job_completions')
        .select('id, post_id, created_at')
        .eq('status', 'pending_approval')
        .lt('created_at', overdueCutoff)
        .limit(500)),
      must<Row[]>(this.db.from('posts')
        .select('id, title, created_at')
        .eq('status', 'assigned')
        .is('archived_at', null)
        .limit(500)),
    ]);

    // Completions: the provider did the work; the client has not answered.
    const titles = await this.titles((completions ?? []).map((c) => c.post_id));
    const overdue = (completions ?? []).map((c): AlertItem => ({
      id: c.id,
      label: truncate(titles.get(c.post_id)),
      detail: `Marked done ${ageOf(c.created_at, now)} ago; payout waits on the client`,
      at: c.created_at,
      href: '/dashboard/marketplace/active-jobs',
    }));

    // Hired, never paid. The selection time comes from the event log, falling
    // back to the listing's own age when that event is missing.
    let unpaid: AlertItem[] = [];
    const posts = assigned ?? [];
    if (posts.length) {
      const ids = posts.map((p) => p.id as string);
      const [{ data: paid }, { data: selected }] = await Promise.all([
        must<Row[]>(this.db.from('transactions').select('post_id').in('post_id', ids).in('status', [...RECEIVED]).limit(2000)),
        must<Row[]>(this.db.from('system_events')
          .select('entity_id, created_at')
          .eq('type', 'post.provider_selected')
          .in('entity_id', ids)
          .order('created_at', { ascending: false })
          .limit(2000)),
      ]);
      const paidPosts = new Set((paid ?? []).map((t) => t.post_id));
      const selectedAt = new Map<string, string>();
      for (const ev of selected ?? []) if (!selectedAt.has(ev.entity_id)) selectedAt.set(ev.entity_id, ev.created_at);
      unpaid = posts
        .filter((p) => !paidPosts.has(p.id))
        .map((p) => ({ p, since: selectedAt.get(p.id) ?? p.created_at }))
        .filter(({ since }) => age(since, now) >= THRESHOLDS.assignedUnpaidHours * HOUR && age(since, now) <= THRESHOLDS.assignedUnpaidWindowDays * DAY)
        .map(({ p, since }) => ({
          id: p.id,
          label: truncate(p.title),
          detail: `Provider chosen ${ageOf(since, now)} ago; no payment`,
          at: since,
          href: '/dashboard/marketplace/active-jobs',
        }));
    }

    return [
      buildAlert('completion_overdue', overdue, () => `Over ${THRESHOLDS.completionOverdueHours}h with no approval. There is no automatic approval.`),
      buildAlert('assigned_unpaid', unpaid, () => 'The client picked a provider and stopped there.'),
    ];
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Demand nobody answered — the supply signal
  // ═══════════════════════════════════════════════════════════════════════════

  private async requestAlerts(now: number): Promise<Array<AdminAlert | null>> {
    const since = new Date(now - THRESHOLDS.requestWindowDays * DAY).toISOString();
    const { data } = await must<Row[]>(this.db.from('posts')
      .select('id, title, urgency, is_urgent, category, location, created_at')
      .eq('type', 'request')
      .eq('status', 'open')
      .is('archived_at', null)
      .gte('created_at', since)
      .limit(500));
    const open = data ?? [];
    if (open.length === 0) return [];

    const { data: apps } = await must<Row[]>(this.db.from('applications')
      .select('post_id')
      .in('post_id', open.map((p) => p.id))
      .limit(5000));
    const answered = new Set((apps ?? []).map((a) => a.post_id));

    const urgent: AlertItem[] = [];
    const regular: AlertItem[] = [];
    for (const p of open) {
      if (answered.has(p.id)) continue;
      const waited = age(p.created_at, now);
      const isUrgent = p.urgency === 'urgent' || p.is_urgent === true;
      const entry: AlertItem = {
        id: p.id,
        label: truncate(p.title),
        detail: [p.category, p.location, `posted ${ageOf(p.created_at, now)} ago`].filter(Boolean).join(' · '),
        at: p.created_at,
        href: '/dashboard/marketplace/requests?status=open',
      };
      if (isUrgent && waited >= THRESHOLDS.urgentUnansweredHours * HOUR && waited <= THRESHOLDS.urgentWindowDays * DAY) {
        urgent.push(entry);
      } else if (waited >= THRESHOLDS.requestUnansweredHours * HOUR) {
        regular.push(entry);
      }
    }
    return [
      buildAlert('urgent_unanswered', urgent, () => `Marked urgent, and nobody has offered in ${THRESHOLDS.urgentUnansweredHours}h or more.`),
      buildAlert('requests_unanswered', regular, () => 'Demand with no supply. Worth knowing which categories and places.'),
    ];
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Promotions — a customer has paid and is waiting on us
  // ═══════════════════════════════════════════════════════════════════════════

  private async promotionAlerts(): Promise<Array<AdminAlert | null>> {
    const { data } = await must<Row[]>(this.db.from('promotion_campaigns')
      .select('id, post_title, package_name, price_kes, created_at, updated_at')
      .eq('status', 'pending_review')
      .limit(200));
    return [
      buildAlert('promotion_review', (data ?? []).map((c): AlertItem => ({
        id: c.id,
        label: truncate(c.post_title),
        detail: c.package_name ? `${c.package_name} package` : undefined,
        at: c.updated_at ?? c.created_at,
        amount_kes: c.price_kes ?? null,
        href: `/dashboard/promotion/${c.id}`,
      })), () => 'Paid for and waiting to go live.'),
    ];
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  private async titles(postIds: Array<string | null | undefined>): Promise<Map<string, string>> {
    const ids = unique(postIds.filter((x): x is string => !!x));
    if (ids.length === 0) return new Map();
    const { data } = await must<Row[]>(this.db.from('posts').select('id, title').in('id', ids).limit(1000));
    return new Map((data ?? []).map((p) => [p.id as string, p.title as string]));
  }
}

async function must<T>(query: PromiseLike<Result<T>>): Promise<{ data: T | null }> {
  const { data, error } = await query;
  if (error) throw new Error(error.message);
  return { data };
}

function first(v: unknown): Row | null {
  if (Array.isArray(v)) return (v[0] as Row) ?? null;
  return (v as Row) ?? null;
}

function unique<T>(xs: T[]): T[] {
  return [...new Set(xs)];
}

function age(iso: string | null | undefined, now: number): number {
  const t = iso ? Date.parse(iso) : NaN;
  return Number.isFinite(t) ? now - t : 0;
}

/** Which impossibility this is, in words — "inconsistent" alone tells an admin nothing. */
function mismatchReason(tx: Row, escrow: Row | null, disputeOpen: boolean): string {
  const t = tx.status as string;
  const e = (escrow?.status as string | undefined) ?? null;
  if (!e) return `Payment ${t}, but there is no escrow record`;
  if (disputeOpen) return `A dispute is open, but the money is already ${t === 'released' || e === 'released' ? 'released' : 'refunded'}`;
  if (t === 'disputed' || e === 'disputed') return 'Frozen as disputed, but no dispute is open';
  return `Payment ${t}, escrow ${e}`;
}

function sum(items: AlertItem[]): number {
  return items.reduce((s, i) => s + (i.amount_kes ?? 0), 0);
}

function humanise(s: unknown): string {
  const t = String(s ?? '').replace(/_/g, ' ').trim();
  return t ? t.charAt(0).toUpperCase() + t.slice(1) : '—';
}

function targetWord(t: unknown): string {
  return t === 'post' ? 'a listing' : t === 'message' ? 'a message' : t === 'application' ? 'an application' : 'an account';
}
