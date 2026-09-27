import { createHash } from 'crypto';

/**
 * THE ADMIN ALERT CATALOGUE.
 *
 * An alert is a CONDITION in live data that an admin can act on — not an event
 * log. Each one is derived on read from the records the rest of the platform
 * already keeps (transactions/escrow through deriveSettlementState, disputes and
 * their SLA sweep, job completions, reports, listings, campaigns), so it clears
 * itself the moment the underlying problem is fixed. Nothing here is stored,
 * and nothing can drift from the truth it describes.
 *
 * WHAT EARNS A PLACE
 * ------------------
 *   high    Money is at risk or owed, or a person may be at risk. Act now.
 *   medium  A queue is waiting on an admin, or money is held longer than the
 *           workflow intends. Review today.
 *   low     Marketplace health. Nobody's money or safety is at stake; worth a
 *           look when the queue is clear.
 *
 * And deliberately NOT here (see docs in the dashboard panel):
 *   - provider verifications — the product has no verification step to act on;
 *   - failed STK attempts — people cancel prompts; that is not an incident;
 *   - dead-lettered system events — an engineering signal for logs/monitoring;
 *   - new signups/listings — information, not attention.
 */

export type AlertPriority = 'high' | 'medium' | 'low';
export type AlertCategory = 'financial' | 'trust_safety' | 'marketplace';

export type AlertId =
  | 'payout_failed'
  | 'payout_stuck'
  | 'provider_owed'
  | 'money_mismatch'
  | 'phantom_escrow'
  | 'payment_unconfirmed'
  | 'dispute_escalated'
  | 'dispute_awaiting_admin'
  | 'reports_urgent'
  | 'reports_untriaged'
  | 'completion_overdue'
  | 'paid_stalled'
  | 'urgent_unanswered'
  | 'promotion_review'
  | 'assigned_unpaid'
  | 'requests_unanswered';

/** Every threshold in one place, so a number in the panel is never a guess. */
export const THRESHOLDS = {
  /** B2C results normally land in seconds; half an hour means the callback is lost. */
  payoutStuckMinutes: 30,
  /** Daraja answers every STK prompt (paid, failed, cancelled, timed out) within minutes. */
  paymentUnconfirmedMinutes: 60,
  /** There is no auto-approval: a provider's money waits on the client indefinitely. */
  completionOverdueHours: 72,
  /** A paid job with no completion request after two weeks has likely been abandoned. */
  paidStalledDays: 14,
  /** Provider chosen, nobody paid: the job is stuck before it started. */
  assignedUnpaidHours: 72,
  /** After a month an unpaid hire is a dead listing, not a nudge anyone can make. */
  assignedUnpaidWindowDays: 30,
  /** An urgent request is time-sensitive by definition. */
  urgentUnansweredHours: 2,
  requestUnansweredHours: 24,
  /** Older unanswered requests are stale, not actionable. */
  urgentWindowDays: 7,
  requestWindowDays: 14,
} as const;

export interface AlertItem {
  id: string;
  label: string;
  detail?: string;
  at: string | null;
  amount_kes?: number | null;
  href?: string;
}

export interface AdminAlert {
  id: AlertId;
  category: AlertCategory;
  priority: AlertPriority;
  title: string;
  detail: string;
  /** What the admin should do about it, in a few words. */
  action: string;
  count: number;
  amount_kes: number | null;
  oldest_at: string | null;
  latest_at: string | null;
  href: string;
  /**
   * Changes whenever the set of affected records changes. The dashboard lets an
   * admin acknowledge an alert for exactly this set; a new record re-raises it.
   */
  fingerprint: string;
  /** The first few affected records, oldest first. */
  items: AlertItem[];
}

interface RuleMeta {
  category: AlertCategory;
  priority: AlertPriority;
  href: string;
  action: string;
  title: (n: number) => string;
}

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

export const RULES: Readonly<Record<AlertId, RuleMeta>> = {
  // ── Financial & escrow ───────────────────────────────────────────────────
  payout_failed: {
    category: 'financial',
    priority: 'high',
    href: '/dashboard/payments/escrow',
    action: 'Retry or pay out manually',
    title: (n) => `${plural(n, 'payout', 'payouts')} failed — provider not paid`,
  },
  payout_stuck: {
    category: 'financial',
    priority: 'high',
    href: '/dashboard/payments/escrow',
    action: 'Check with M-Pesa',
    title: (n) => `${plural(n, 'payout has', 'payouts have')} had no M-Pesa result`,
  },
  provider_owed: {
    category: 'financial',
    priority: 'high',
    href: '/dashboard/disputes/resolved',
    action: "Settle the provider's share",
    title: (n) => `${plural(n, 'provider is', 'providers are')} owed from a split decision`,
  },
  money_mismatch: {
    category: 'financial',
    priority: 'high',
    href: '/dashboard/payments/escrow',
    action: 'Reconcile the records',
    title: (n) => `${plural(n, 'payment needs', 'payments need')} reconciling`,
  },
  phantom_escrow: {
    category: 'financial',
    priority: 'medium',
    href: '/dashboard/payments/failed',
    action: 'Clear the stale hold',
    title: (n) => `${plural(n, 'escrow hold has', 'escrow holds have')} no payment behind it`,
  },
  payment_unconfirmed: {
    category: 'financial',
    priority: 'medium',
    href: '/dashboard/payments/pending',
    action: 'Check the M-Pesa statement',
    title: (n) => `${plural(n, 'payment was', 'payments were')} never confirmed`,
  },
  dispute_escalated: {
    category: 'financial',
    priority: 'high',
    href: '/dashboard/disputes?status=escalated',
    action: 'Decide the case',
    title: (n) => `${plural(n, 'dispute', 'disputes')} escalated`,
  },
  dispute_awaiting_admin: {
    category: 'financial',
    priority: 'medium',
    href: '/dashboard/disputes',
    action: 'Respond to the parties',
    title: (n) => `${plural(n, 'dispute is', 'disputes are')} waiting on an admin`,
  },

  // ── Trust & safety ───────────────────────────────────────────────────────
  reports_urgent: {
    category: 'trust_safety',
    priority: 'high',
    href: '/dashboard/trust-safety/queue?scope=unassigned',
    action: 'Claim and review',
    title: (n) => `${plural(n, 'serious report', 'serious reports')} unassigned`,
  },
  reports_untriaged: {
    category: 'trust_safety',
    priority: 'medium',
    href: '/dashboard/trust-safety/queue?scope=new',
    action: 'Triage',
    title: (n) => `${plural(n, 'report', 'reports')} awaiting triage`,
  },

  // ── Marketplace health ───────────────────────────────────────────────────
  completion_overdue: {
    category: 'marketplace',
    priority: 'medium',
    href: '/dashboard/marketplace/active-jobs',
    action: 'Nudge the client',
    title: (n) => `${plural(n, 'finished job is', 'finished jobs are')} waiting on client approval`,
  },
  paid_stalled: {
    category: 'marketplace',
    priority: 'medium',
    href: '/dashboard/marketplace/active-jobs',
    action: 'Check in with both parties',
    title: (n) => `${plural(n, 'paid job has', 'paid jobs have')} made no progress`,
  },
  urgent_unanswered: {
    category: 'marketplace',
    priority: 'medium',
    href: '/dashboard/marketplace/requests?status=open',
    action: 'Find a provider',
    title: (n) => `${plural(n, 'urgent request has', 'urgent requests have')} no responses`,
  },
  promotion_review: {
    category: 'marketplace',
    priority: 'medium',
    href: '/dashboard/promotion?status=pending_review',
    action: 'Approve or reject',
    title: (n) => `${plural(n, 'paid promotion is', 'paid promotions are')} awaiting review`,
  },
  assigned_unpaid: {
    category: 'marketplace',
    priority: 'low',
    href: '/dashboard/marketplace/active-jobs',
    action: 'Follow up with the client',
    title: (n) => `${plural(n, 'hired job was', 'hired jobs were')} never paid for`,
  },
  requests_unanswered: {
    category: 'marketplace',
    priority: 'low',
    href: '/dashboard/marketplace/requests?status=open',
    action: 'Recruit supply',
    title: (n) => `${plural(n, 'request has', 'requests have')} had no response for a day`,
  },
};

const PRIORITY_RANK: Record<AlertPriority, number> = { high: 0, medium: 1, low: 2 };
const CATEGORY_RANK: Record<AlertCategory, number> = { financial: 0, trust_safety: 1, marketplace: 2 };

/** Stable across ordering; changes when the set of records does. */
export function fingerprint(ids: string[]): string {
  return createHash('sha1').update([...ids].sort().join('|')).digest('hex').slice(0, 16);
}

export const MAX_ITEMS = 5;

/**
 * Turn the affected records into an alert, or null when there are none — an
 * alert with nothing behind it does not exist.
 */
export function buildAlert(id: AlertId, items: AlertItem[], detail: (items: AlertItem[]) => string): AdminAlert | null {
  if (items.length === 0) return null;
  const meta = RULES[id];
  const sorted = [...items].sort((a, b) => time(a.at) - time(b.at));
  const amounts = items.map((i) => i.amount_kes).filter((v): v is number => typeof v === 'number');
  return {
    id,
    category: meta.category,
    priority: meta.priority,
    title: meta.title(items.length),
    detail: detail(sorted),
    action: meta.action,
    count: items.length,
    amount_kes: amounts.length ? amounts.reduce((s, v) => s + v, 0) : null,
    oldest_at: sorted[0]?.at ?? null,
    latest_at: sorted[sorted.length - 1]?.at ?? null,
    href: meta.href,
    fingerprint: fingerprint(items.map((i) => i.id)),
    items: sorted.slice(0, MAX_ITEMS),
  };
}

/** Most urgent first; within a priority, money before safety before health, oldest first. */
export function sortAlerts(alerts: AdminAlert[]): AdminAlert[] {
  return [...alerts].sort(
    (a, b) =>
      PRIORITY_RANK[a.priority] - PRIORITY_RANK[b.priority] ||
      CATEGORY_RANK[a.category] - CATEGORY_RANK[b.category] ||
      time(a.oldest_at) - time(b.oldest_at),
  );
}

function time(iso: string | null | undefined): number {
  const t = iso ? Date.parse(iso) : NaN;
  return Number.isFinite(t) ? t : Number.MAX_SAFE_INTEGER;
}

// ── Copy helpers ────────────────────────────────────────────────────────────

export function kes(n: number | null | undefined): string {
  return n == null ? 'KES —' : `KES ${Math.round(n).toLocaleString('en-KE')}`;
}

/** "3h", "5d" — how long something has waited. */
export function ageOf(iso: string | null | undefined, now = Date.now()): string {
  if (!iso) return 'unknown';
  const h = Math.max(0, (now - Date.parse(iso)) / 3_600_000);
  if (h < 1) return `${Math.max(1, Math.round(h * 60))}m`;
  if (h < 48) return `${Math.round(h)}h`;
  return `${Math.round(h / 24)}d`;
}

export function truncate(s: string | null | undefined, max = 60): string {
  const t = (s ?? '').trim();
  if (!t) return 'Untitled listing';
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
}
