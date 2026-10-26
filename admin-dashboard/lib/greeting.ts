import type { AdminAlert } from "./alerts";

/**
 * The Overview greeting, as pure functions (lib/greeting.test.mjs pins them).
 *
 * Computed in the BROWSER only: Overview is cached and shared by every admin
 * (revalidate 60), so a name rendered on the server would be served to the
 * next admin too, and a time of day rendered there would be the server's.
 */

export const DEFAULT_TIME_ZONE = "Africa/Nairobi";

/** The viewer's own zone, or Nairobi when the browser will not say. */
export function viewerTimeZone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || DEFAULT_TIME_ZONE;
  } catch {
    return DEFAULT_TIME_ZONE;
  }
}

/** Hour 0–23 in `timeZone`. */
export function hourIn(timeZone: string, now: Date = new Date()): number {
  const h = new Intl.DateTimeFormat("en-GB", { hour: "numeric", hourCycle: "h23", timeZone }).format(now);
  return Number.parseInt(h, 10) % 24;
}

/** 05–11 morning, 12–16 afternoon, 17–20 evening, otherwise "Welcome back". */
export function greetingForHour(hour: number): string {
  if (hour >= 5 && hour < 12) return "Good morning";
  if (hour >= 12 && hour < 17) return "Good afternoon";
  if (hour >= 17 && hour < 21) return "Good evening";
  return "Welcome back";
}

/** "Monday, 26 October" in `timeZone`. */
export function dateLine(timeZone: string, now: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-GB", { weekday: "long", day: "numeric", month: "long", timeZone }).formatToParts(now);
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  return `${get("weekday")}, ${get("day")} ${get("month")}`;
}

/**
 * The first name to greet. The profile name's first word; else the email's
 * local part up to the first separator, digits removed, capitalised
 * ("john.doe92@…" → "John"); else nothing — the greeting then stands alone.
 */
export function firstNameFrom(name: string | null | undefined, email: string | null | undefined): string | null {
  const fromName = name?.trim().split(/\s+/)[0];
  if (fromName) return fromName;

  const local = email?.split("@")[0] ?? "";
  const word = (local.split(/[._+\-]/).find((s) => /[a-z]/i.test(s)) ?? "").replace(/[^a-z]/gi, "");
  if (word.length < 2) return null;
  return word.charAt(0).toUpperCase() + word.slice(1).toLowerCase();
}

export type AttentionItem = { text: string; href: string; count: number };

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/**
 * What the context line can mention, in the order it is mentioned. Each row
 * sums the unreviewed alerts it covers (alert ids from the backend catalogue,
 * backend/src/admin/alerts/alert-rules.ts) and links where they are acted on.
 * Provider verifications are absent on purpose: the product has no
 * verification step, so there is nothing pending to count.
 */
const ATTENTION: Array<{ ids: string[]; href: string; text: (n: number) => string }> = [
  { ids: ["dispute_escalated", "dispute_awaiting_admin"], href: "/dashboard/disputes", text: (n) => `${plural(n, "dispute needs", "disputes need")} review` },
  { ids: ["payout_failed"], href: "/dashboard/payments/escrow", text: (n) => plural(n, "failed payout", "failed payouts") },
  { ids: ["reports_urgent", "reports_untriaged"], href: "/dashboard/trust-safety/queue", text: (n) => `${plural(n, "report", "reports")} to triage` },
  { ids: ["requests_unanswered", "urgent_unanswered"], href: "/dashboard/marketplace/requests?status=open", text: (n) => `${plural(n, "request", "requests")} awaiting providers` },
  { ids: ["promotion_review"], href: "/dashboard/promotion?status=pending_review", text: (n) => `${plural(n, "promotion", "promotions")} awaiting review` },
  { ids: ["dashboard_login_unlinked"], href: "/dashboard/users/admins#unlinked-logins", text: (n) => `${plural(n, "login", "logins")} waiting to be linked` },
];

/** Non-zero items, most pressing first, at most `max`. Reviewed alerts are settled, so they do not count. */
export function attentionItems(alerts: AdminAlert[], max = 3): AttentionItem[] {
  const open = alerts.filter((a) => !a.review);
  return ATTENTION.map((row) => {
    const count = open.filter((a) => row.ids.includes(a.id)).reduce((s, a) => s + (a.count ?? 0), 0);
    return { text: row.text(count), href: row.href, count };
  })
    .filter((i) => i.count > 0)
    .slice(0, max);
}
