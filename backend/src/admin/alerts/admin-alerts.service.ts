import { BadRequestException, ConflictException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { SupabaseService } from '../../supabase/supabase.service';
import { deriveSettlementState } from '../../jobs/settlement-state';
import { toHttpError } from '../../moderation/moderation-errors';
import { AdminContext } from '../auth/admin-role';
import { AlertReviewDto } from './dto/alert-review.dto';
import {
  AdminAlert,
  AlertId,
  AlertItem,
  MONEY_STATE_LABELS,
  MoneyAlertId,
  RULES,
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
  /** Bumped by invalidate(), so a computation started before a write is not cached after it. */
  private generation = 0;

  constructor(
    private readonly supabase: SupabaseService,
    private readonly config: ConfigService,
  ) {}

  private get db() {
    return this.supabase.client;
  }

  list(): Promise<AlertsResponse> {
    const now = Date.now();
    if (this.cache && now - this.cache.at < AdminAlertsService.CACHE_MS) return Promise.resolve(this.cache.value);
    const generation = this.generation;
    this.inFlight ??= this.compute(now)
      .then((value) => {
        if (generation === this.generation) this.cache = { at: Date.now(), value };
        return value;
      })
      .finally(() => {
        this.inFlight = null;
      });
    return this.inFlight;
  }

  /** Drop the shared result — after a review or a finance repair changes the answer. */
  invalidate(): void {
    this.generation += 1;
    this.cache = null;
    this.inFlight = null;
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
    await this.attachReviews(alerts, unavailable);
    return { generated_at: new Date(now).toISOString(), alerts, unavailable };
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Reviews — shared by every admin, bound to the exact records reviewed
  // ═══════════════════════════════════════════════════════════════════════════

  /**
   * Mark an alert reviewed (or reopen it) for the set of records the admin
   * actually saw. The fingerprint must match the alert as it is NOW: a review
   * never covers records that joined after the admin looked.
   */
  async review(admin: AdminContext, alertId: string, dto: AlertReviewDto): Promise<AdminAlert> {
    if (!(alertId in RULES)) {
      throw new NotFoundException({ code: 'ALERT_UNKNOWN', message: 'There is no such alert.' });
    }
    const note = dto.note?.trim() ?? '';
    if (dto.action === 'reviewed' && note.length < 5) {
      throw new BadRequestException({ code: 'ALERT_REVIEW_NOTE', message: 'Say why it needs nothing more — at least 5 characters.' });
    }
    const current = (await this.compute()).alerts.find((a) => a.id === alertId);
    if (!current) {
      throw new NotFoundException({ code: 'ALERT_CLEARED', message: 'This alert has already cleared — there is nothing to review.' });
    }
    if (current.fingerprint !== dto.fingerprint) {
      throw new ConflictException({
        code: 'ALERT_CHANGED',
        message: 'This alert changed since you opened it. Check again, then review what is there now.',
      });
    }
    if (dto.action === 'reviewed' && current.review) return current;
    if (dto.action === 'reopened' && !current.review) {
      throw new ConflictException({ code: 'ALERT_NOT_REVIEWED', message: 'This alert is not marked reviewed.' });
    }

    const { error } = await this.db.from('admin_alert_reviews').insert({
      alert_id: alertId,
      fingerprint: dto.fingerprint,
      action: dto.action,
      note: note || null,
      admin_id: admin.id,
      admin_email: admin.email,
      admin_role: admin.role,
    });
    if (error) throw toHttpError(error);
    this.logger.log(`[ALERTS] ${alertId} ${dto.action} by=${admin.email} (${admin.role}) fp=${dto.fingerprint}`);
    this.invalidate();
    return (await this.list()).alerts.find((a) => a.id === alertId) ?? current;
  }

  private async attachReviews(alerts: AdminAlert[], unavailable: AlertsResponse['unavailable']): Promise<void> {
    for (const a of alerts) a.review = null;
    if (alerts.length === 0) return;
    try {
      const { data } = await must<Row[]>(this.db.from('admin_alert_reviews')
        .select('alert_id, fingerprint, action, note, admin_email, admin_role, created_at')
        .in('alert_id', unique(alerts.map((a) => a.id)))
        .order('created_at', { ascending: false })
        .limit(500));
      const latest = new Map<string, Row>();
      for (const r of data ?? []) if (!latest.has(r.alert_id)) latest.set(r.alert_id, r);
      for (const a of alerts) {
        const r = latest.get(a.id);
        a.review = r && r.action === 'reviewed' && r.fingerprint === a.fingerprint
          ? { note: r.note, admin_email: r.admin_email, admin_role: r.admin_role, at: r.created_at }
          : null;
      }
    } catch (e) {
      // Unreviewed is the safe reading: the alert still counts on the bell.
      this.logger.warn(`[ALERTS] reviews unavailable: ${e instanceof Error ? e.message : String(e)}`);
      unavailable.push({ source: 'reviews', reason: 'This check could not run.' });
    }
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
      must<Row[]>(this.db.from('disputes')
        .select('id, post_id, transaction_id, status, created_at')
        .order('created_at', { ascending: false })
        .limit(2000)),
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
    // The newest dispute on each payment — where its ruling, and the repairs
    // for money a ruling left behind, live in the dashboard.
    const disputeOf = new Map<string, string>();
    for (const d of disputes) {
      const txId = d.transaction_id ?? latestTxByPost.get(d.post_id);
      if (txId && !disputeOf.has(txId)) disputeOf.set(txId, d.id);
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

    // A split share stops being owed once finance recorded paying it
    // (admin_record_manual_settlement, migration 117).
    let owed = buckets.owed;
    if (owed.length) {
      const { data: legs } = await must<Row[]>(this.db.from('settlements')
        .select('transaction_id')
        .in('transaction_id', owed.map((e) => e.tx.id as string))
        .eq('direction', 'provider_payout')
        .in('status', ['completed', 'succeeded'])
        .limit(1000));
      const paid = new Set((legs ?? []).map((l) => l.transaction_id));
      owed = owed.filter((e) => !paid.has(e.tx.id));
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

    const flagged = [...buckets.failed, ...buckets.processing, ...owed, ...buckets.mismatch,
      ...buckets.phantom, ...buckets.unconfirmed, ...stalled];
    const titles = await this.titles(flagged.map((e) => e.tx.post_id));

    // `amount` omitted → the payment's own total; an explicit null → no money
    // involved (a hold with no payment behind it must not claim one).
    const item = (
      e: { tx: Row; escrow: Row | null },
      at: string | null,
      detail: string,
      amount?: number | null,
      href = '/dashboard/payments/escrow',
    ): AlertItem => ({
      id: e.tx.id,
      // transactions.post_id has no foreign key, so it can outlive its listing.
      label: titles.has(e.tx.post_id) ? truncate(titles.get(e.tx.post_id)) : `Listing not found (${String(e.tx.post_id).slice(0, 8)})`,
      detail,
      at,
      amount_kes: amount === undefined ? (e.tx.total_paid ?? e.tx.amount ?? null) : amount,
      href,
    });
    const disputePage = (e: { tx: Row }) =>
      disputeOf.has(e.tx.id) ? `/dashboard/disputes/${disputeOf.get(e.tx.id)}` : '/dashboard/payments/escrow';
    // The job, where both people's phones are — unless its listing is gone.
    const jobOrEscrow = (e: { tx: Row }) =>
      titles.has(e.tx.post_id) ? jobPage(e.tx.post_id) : '/dashboard/payments/escrow';

    // Real money raises its own alerts; test money (the Daraja sandbox, or
    // anything from before the production cutover) is listed once, quietly.
    const mode = this.moneyMode();
    const real: Record<MoneyAlertId, AlertItem[]> = {
      payout_failed: [], payout_stuck: [], provider_owed: [], money_mismatch: [],
      phantom_escrow: [], payment_unconfirmed: [], paid_stalled: [],
    };
    const test: AlertItem[] = [];
    const add = (rule: MoneyAlertId, e: { tx: Row }, it: AlertItem) => {
      if (mode.isTest(e.tx.created_at)) test.push({ ...it, detail: `${MONEY_STATE_LABELS[rule]} — ${it.detail}` });
      else real[rule].push(it);
    };

    const stuck = buckets.processing
      .map((e) => ({ e, since: sentAt.get(e.tx.id) ?? e.tx.created_at }))
      .filter(({ since }) => age(since, now) >= THRESHOLDS.payoutStuckMinutes * MINUTE);

    for (const e of buckets.failed) {
      add('payout_failed', e, item(e, failedAt.get(e.tx.id) ?? e.tx.created_at, `M-Pesa said: ${truncate(e.tx.failure_reason, 80)}`,
        undefined, jobOrEscrow(e)));
    }
    for (const { e, since } of stuck) {
      add('payout_stuck', e, item(e, since, `Sent to M-Pesa ${ageOf(since, now)} ago, no result since`));
    }
    for (const e of owed) {
      const d = decision.get(e.tx.id);
      add('provider_owed', e, item(e, d?.created_at ?? e.tx.created_at, 'Split decided; provider share not recorded as paid',
        d?.provider_amount ?? null, disputePage(e)));
    }
    for (const e of buckets.mismatch) {
      add('money_mismatch', e, item(e, e.tx.created_at, mismatchReason(e.tx, e.escrow, frozen.has(e.tx.id)), undefined, disputePage(e)));
    }
    for (const e of buckets.phantom) {
      add('phantom_escrow', e, item(e, e.escrow?.created_at ?? e.tx.created_at,
        `Payment ${e.tx.status}, escrow ${e.escrow?.status ?? 'missing'}`, null, '/dashboard/payments/failed'));
    }
    for (const e of buckets.unconfirmed) {
      add('payment_unconfirmed', e, item(e, e.tx.created_at, `STK prompt sent ${ageOf(e.tx.created_at, now)} ago, no result recorded`,
        undefined, '/dashboard/payments/pending'));
    }
    for (const e of stalled) {
      add('paid_stalled', e, item(e, e.tx.created_at, `Paid ${ageOf(e.tx.created_at, now)} ago, no completion requested`,
        undefined, jobOrEscrow(e)));
    }

    return [
      buildAlert('payout_failed', real.payout_failed,
        (items) => `${kes(sum(items))} owed to providers, still held in escrow. The dashboard cannot retry a payout yet; engineering can.`),
      buildAlert('payout_stuck', real.payout_stuck,
        (items) => `${kes(sum(items))} in flight. Asking M-Pesa for the result settles it only if it succeeded.`),
      buildAlert('provider_owed', real.provider_owed,
        (items) => `${kes(sum(items))} ruled for providers and not yet recorded as paid. Record the payment on the dispute once finance has sent it.`),
      buildAlert('money_mismatch', real.money_mismatch,
        (items) => `${kes(sum(items))} received, in a state the payment workflow cannot produce. Where a closed dispute left the money frozen, apply its ruling on the dispute; anything else needs engineering.`),
      buildAlert('phantom_escrow', real.phantom_escrow,
        () => "No money was received. Escrow is created when a payment starts, so a failed one leaves the hold — which blocks the owner from removing the listing. Don't delete these by hand: see docs/escrow-cleanup-design.md."),
      buildAlert('payment_unconfirmed', real.payment_unconfirmed,
        () => 'M-Pesa never reported back. If the customer paid, the money is unattributed.'),
      buildAlert('paid_stalled', real.paid_stalled,
        (items) => `${kes(sum(items))} held with no sign of the work being done.`),
      buildAlert('sandbox_money', test, () => mode.describe),
    ];
  }

  /**
   * Whether a payment was test money. While MPESA_ENV is not "production" every
   * payment went through the Daraja sandbox; after the cutover, set
   * MPESA_PRODUCTION_SINCE so the earlier test payments stay classed as tests.
   * Unset after a cutover, everything counts as real — the noisy side, never
   * the silent one.
   */
  private moneyMode(): { isTest: (createdAt: string | null | undefined) => boolean; describe: string } {
    const env = String(this.config.get<string>('MPESA_ENV', 'sandbox') ?? 'sandbox').toLowerCase();
    if (env !== 'production') {
      return {
        isTest: () => true,
        describe: 'M-Pesa still runs on the Daraja sandbox (MPESA_ENV=sandbox), so none of this is real money. Each line says the state it was left in.',
      };
    }
    const since = Date.parse(String(this.config.get<string>('MPESA_PRODUCTION_SINCE') ?? ''));
    if (Number.isFinite(since)) {
      return {
        isTest: (createdAt) => !!createdAt && Date.parse(createdAt) < since,
        describe: `Made before M-Pesa went live on ${new Date(since).toISOString().slice(0, 10)} — test money. Each line says the state it was left in.`,
      };
    }
    return { isTest: () => false, describe: '' };
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
      href: jobPage(c.post_id),
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
          href: jobPage(p.id),
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
        href: jobPage(p.id),
      };
      if (isUrgent && waited >= THRESHOLDS.urgentUnansweredHours * HOUR && waited <= THRESHOLDS.urgentWindowDays * DAY) {
        urgent.push(entry);
      } else if (waited >= THRESHOLDS.requestUnansweredHours * HOUR) {
        regular.push(entry);
      }
    }
    return [
      buildAlert('urgent_unanswered', urgent, () => `Marked urgent, and nobody has offered in ${THRESHOLDS.urgentUnansweredHours}h or more.`),
      buildAlert('requests_unanswered', regular,
        () => 'Nobody has offered. Each request shows who on Help24 could take it, or that nobody offers that work yet.'),
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

/** A listing's own dashboard page: both people's phones, and who could take it. */
function jobPage(postId: string): string {
  return `/dashboard/marketplace/requests/${encodeURIComponent(postId)}`;
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
