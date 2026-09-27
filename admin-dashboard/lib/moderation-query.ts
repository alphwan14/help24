/**
 * URL search params → the /admin/moderation API's query.
 *
 * Only known values pass through; anything else is dropped here rather than
 * bounced by the API's validator as a 400 the admin cannot act on.
 */

import { REPORT_CATEGORIES, REPORT_STATUSES, SEVERITIES, TARGET_LABELS } from "./moderation-labels";

export type SearchParams = Record<string, string | string[] | undefined>;

export const PAGE_SIZE = 25;

function one(sp: SearchParams, key: string): string | undefined {
  const v = sp[key];
  const s = Array.isArray(v) ? v[0] : v;
  return s && s.trim() ? s.trim() : undefined;
}

const DATE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * A calendar day in Nairobi (UTC+3, no daylight saving). An admin who picks
 * "27 Sep" means the Kenyan day, not the UTC one — a report filed at 01:00
 * EAT on the 28th must not land on the 27th.
 */
export function dayBoundary(day: string | undefined, edge: "start" | "end"): string | undefined {
  if (!day || !DATE.test(day)) return undefined;
  return edge === "start" ? `${day}T00:00:00+03:00` : `${day}T23:59:59.999+03:00`;
}

export function offsetOf(sp: SearchParams): number {
  const n = Number(one(sp, "offset"));
  return Number.isFinite(n) && n > 0 ? Math.min(Math.floor(n), 10_000) : 0;
}

/** The filter values the form shows (raw, as typed). */
export function reportFilterValues(sp: SearchParams) {
  const status = one(sp, "status");
  const severity = one(sp, "severity");
  const category = one(sp, "category");
  const target = one(sp, "target_type");
  const assigned = one(sp, "assigned");
  const from = one(sp, "from");
  const to = one(sp, "to");
  const sort = one(sp, "sort");
  return {
    q: one(sp, "q")?.slice(0, 100),
    status: status && ([...REPORT_STATUSES, "open", "closed"] as string[]).includes(status) ? status : undefined,
    severity: severity && (SEVERITIES as readonly string[]).includes(severity) ? severity : undefined,
    category: category && (REPORT_CATEGORIES as readonly string[]).includes(category) ? category : undefined,
    target_type: target && target in TARGET_LABELS ? target : undefined,
    assigned: assigned && ["me", "none"].includes(assigned) ? assigned : undefined,
    from: from && DATE.test(from) ? from : undefined,
    to: to && DATE.test(to) ? to : undefined,
    sort: sort === "queue" ? "queue" : undefined,
  };
}

/** The API query for the reports list. */
export function reportApiQuery(sp: SearchParams, overrides: Record<string, string | number | undefined> = {}) {
  const v = reportFilterValues(sp);
  const reported = one(sp, "reported_user_id");
  const reporter = one(sp, "reporter_id");
  const idOk = (s: string | undefined) => (s && /^[A-Za-z0-9_-]{1,128}$/.test(s) ? s : undefined);
  return {
    q: v.q,
    status: v.status,
    severity: v.severity,
    category: v.category,
    target_type: v.target_type,
    assigned: v.assigned,
    reported_user_id: idOk(reported),
    reporter_id: idOk(reporter),
    from: dayBoundary(v.from, "start"),
    to: dayBoundary(v.to, "end"),
    sort: v.sort === "queue" ? "queue" : "newest",
    limit: PAGE_SIZE,
    offset: offsetOf(sp),
    ...overrides,
  };
}

/** Rebuild a URL for the same view at a different page. */
export function hrefWith(basePath: string, sp: SearchParams, changes: Record<string, string | number | undefined>): string {
  const params = new URLSearchParams();
  for (const [k, raw] of Object.entries(sp)) {
    const v = Array.isArray(raw) ? raw[0] : raw;
    if (v) params.set(k, v);
  }
  for (const [k, v] of Object.entries(changes)) {
    if (v === undefined || v === "" || v === 0) params.delete(k);
    else params.set(k, String(v));
  }
  const qs = params.toString();
  return qs ? `${basePath}?${qs}` : basePath;
}

export function param(sp: SearchParams, key: string): string | undefined {
  return one(sp, key);
}
