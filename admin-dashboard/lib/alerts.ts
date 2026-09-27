/**
 * Admin alerts — the shape GET /admin/alerts returns (backend/src/admin/alerts)
 * and how each priority and category reads. Client-safe: no secrets.
 */

export type AlertPriority = "high" | "medium" | "low";
export type AlertCategory = "financial" | "trust_safety" | "marketplace";

export interface AlertItem {
  id: string;
  label: string;
  detail?: string;
  at: string | null;
  amount_kes?: number | null;
  href?: string;
}

/** Set when an admin reviewed exactly the records this alert names now. Shared by every admin. */
export interface AlertReview {
  note: string;
  admin_email: string;
  admin_role: string;
  at: string;
}

export interface AdminAlert {
  id: string;
  category: AlertCategory;
  priority: AlertPriority;
  title: string;
  detail: string;
  action: string;
  count: number;
  amount_kes: number | null;
  oldest_at: string | null;
  latest_at: string | null;
  href: string;
  fingerprint: string;
  items: AlertItem[];
  review?: AlertReview | null;
}

export interface AlertsResponse {
  generated_at: string;
  alerts: AdminAlert[];
  unavailable: Array<{ source: string; reason: string }>;
}

/**
 * The three tiers, and what each asks of an admin. Only HIGH ever puts a
 * number on the bell: a badge that is always lit teaches people to ignore it.
 */
export const PRIORITY_META: Record<AlertPriority, { heading: string; hint: string; dot: string; ring: string }> = {
  high: {
    heading: "Needs action",
    hint: "Money at risk or owed, or someone may be at risk.",
    dot: "bg-critical-500",
    ring: "border-critical-200",
  },
  medium: {
    heading: "Review today",
    hint: "A queue is waiting on us, or money is held longer than it should be.",
    dot: "bg-caution-500",
    ring: "border-caution-200",
  },
  low: {
    heading: "Keep an eye on",
    hint: "Marketplace health. Nobody's money or safety is at stake.",
    dot: "bg-gray-300",
    ring: "border-gray-200",
  },
};

export const CATEGORY_LABELS: Record<AlertCategory, string> = {
  financial: "Money & escrow",
  trust_safety: "Trust & safety",
  marketplace: "Marketplace",
};

export const SOURCE_LABELS: Record<string, string> = {
  payments: "Payments",
  disputes: "Disputes",
  reports: "Reports",
  jobs: "Jobs",
  requests: "Requests",
  promotions: "Promotions",
  reviews: "Review status",
};

export function fmtKesShort(n: number | null | undefined): string | null {
  if (n == null) return null;
  return `KES ${Math.round(n).toLocaleString("en-KE")}`;
}

/** "5m", "3h", "2d" — how long something has waited. */
export function waited(iso: string | null | undefined, now = Date.now()): string | null {
  if (!iso) return null;
  const mins = Math.max(0, (now - Date.parse(iso)) / 60_000);
  if (mins < 60) return `${Math.max(1, Math.round(mins))}m`;
  const h = mins / 60;
  if (h < 48) return `${Math.round(h)}h`;
  return `${Math.round(h / 24)}d`;
}
