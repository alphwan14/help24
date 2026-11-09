/**
 * The figures behind Overview's Growth, Geography and Revenue tabs.
 *
 * Pure functions over rows the pages read (lib/analytics.test.mjs pins them).
 * Every figure is computed for the chosen period and for the equal period
 * before it, so each one can say how it moved.
 *
 * Definitions, kept in one place so all three tabs agree with each other and
 * with the Overview tiles:
 *   - Paid: a transaction whose money was taken (paid, payout_pending,
 *     released). Its `fee` is Help24's job fee; `total_paid` is what the
 *     customer paid (payments volume).
 *   - Earnings: job fees on paid transactions plus paid promotion sales.
 *   - Responded: a request with at least one application.
 *   - Hired: a request with a selected provider (assigned, completed or disputed).
 */

import type { Period, Slot } from "./periods";

/** The slot holding `ms`, or -1 (slots are sorted and contiguous). Kept here
 *  rather than imported so this module has no runtime imports and its tests
 *  run under plain node. */
function slotIndex(slots: Slot[], ms: number): number {
  let lo = 0;
  let hi = slots.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (ms < slots[mid].start) hi = mid - 1;
    else if (ms >= slots[mid].end) lo = mid + 1;
    else return mid;
  }
  return -1;
}

export const PAID = ["paid", "payout_pending", "released"];

const inP = (ms: number, a: number, b: number) => ms >= a && ms < b;
const t = (iso: string | null | undefined) => (iso ? Date.parse(iso) : NaN);

export type Pair = { now: number; before: number };
const pair = (): Pair => ({ now: 0, before: 0 });

/** Which half of the comparison an instant falls in, if either. */
function side(ms: number, p: Period): "now" | "before" | null {
  if (inP(ms, p.start, p.end)) return "now";
  if (inP(ms, p.prevStart, p.prevEnd)) return "before";
  return null;
}

/**
 * Columns for a chart: each slot's value now, and the value of the slot at
 * the same offset in the previous period (the dashed outline).
 */
function columnsFor<T>(
  rows: T[],
  at: (r: T) => number,
  val: (r: T) => number[],
  slots: Slot[],
  p: Period,
  width: number,
): Array<{ values: number[]; previous: number }> {
  const cols = slots.map(() => ({ values: Array(width).fill(0) as number[], previous: 0 }));
  const shift = p.start - p.prevStart;
  for (const r of rows) {
    const ms = at(r);
    if (!Number.isFinite(ms)) continue;
    const v = val(r);
    const s = side(ms, p);
    if (s === "now") {
      const i = slotIndex(slots, ms);
      if (i >= 0) v.forEach((x, k) => (cols[i].values[k] += x));
    } else if (s === "before") {
      const i = slotIndex(slots, ms + shift);
      if (i >= 0) cols[i].previous += v.reduce((a, b) => a + b, 0);
    }
  }
  return cols;
}

/* ─── Revenue ─────────────────────────────────────────────────────────────── */

export type TxRow = { created_at: string; fee: number | null; total_paid: number | null; amount?: number | null; status: string; post_id?: string | null };
export type PromoRow = { paid_at: string | null; created_at: string; amount_kes: number | null };

export function revenue(
  tx: TxRow[],
  promos: PromoRow[],
  categoryOf: Map<string, string>,
  p: Period,
  slots: Slot[],
) {
  const fees = pair(), sales = pair(), volume = pair(), paidJobs = pair(), payouts = pair(), failed = pair(), failedCount = pair();
  const byCat = new Map<string, { jobs: number; volume: number; fees: number }>();

  for (const r of tx) {
    const s = side(t(r.created_at), p);
    if (!s) continue;
    if (PAID.includes(r.status)) {
      fees[s] += r.fee ?? 0;
      volume[s] += r.total_paid ?? 0;
      payouts[s] += r.amount ?? Math.max(0, (r.total_paid ?? 0) - (r.fee ?? 0));
      paidJobs[s] += 1;
      if (s === "now") {
        const cat = (r.post_id && categoryOf.get(r.post_id)) || "Uncategorised";
        const c = byCat.get(cat) ?? { jobs: 0, volume: 0, fees: 0 };
        c.jobs += 1;
        c.volume += r.total_paid ?? 0;
        c.fees += r.fee ?? 0;
        byCat.set(cat, c);
      }
    } else if (r.status === "failed") {
      failed[s] += r.total_paid ?? 0;
      failedCount[s] += 1;
    }
  }
  for (const r of promos) {
    const s = side(t(r.paid_at ?? r.created_at), p);
    if (s) sales[s] += r.amount_kes ?? 0;
  }

  const earnings = { now: fees.now + sales.now, before: fees.before + sales.before };
  const rate = (f: number, v: number) => (v > 0 ? f / v : 0);
  const avg = (v: number, n: number) => (n > 0 ? Math.round(v / n) : 0); // whole KES, like every money figure

  const daily = columnsFor<{ at: number; fee: number; promo: number }>(
    [
      ...tx.filter((r) => PAID.includes(r.status)).map((r) => ({ at: t(r.created_at), fee: r.fee ?? 0, promo: 0 })),
      ...promos.map((r) => ({ at: t(r.paid_at ?? r.created_at), fee: 0, promo: r.amount_kes ?? 0 })),
    ],
    (r) => r.at,
    (r) => [r.fee, r.promo],
    slots,
    p,
    2,
  );

  const categories = [...byCat.entries()]
    .map(([category, c]) => ({ category, ...c, share: fees.now > 0 ? c.fees / fees.now : 0 }))
    .sort((a, b) => b.fees - a.fees || b.volume - a.volume);

  // The best day (or hour, or week) of the period, for a one-line highlight.
  let best = -1;
  daily.forEach((c, i) => {
    if (c.values[0] + c.values[1] > (best >= 0 ? daily[best].values[0] + daily[best].values[1] : 0)) best = i;
  });

  return {
    earnings,
    fees,
    sales,
    volume,
    payouts,
    paidJobs,
    failed,
    failedCount,
    takeRate: { now: rate(fees.now, volume.now), before: rate(fees.before, volume.before) },
    avgJob: { now: avg(volume.now, paidJobs.now), before: avg(volume.before, paidJobs.before) },
    daily,
    best: best >= 0 ? { index: best, value: daily[best].values[0] + daily[best].values[1] } : null,
    categories,
  };
}

/* ─── Growth ──────────────────────────────────────────────────────────────── */

export type UserRow = { id: string; created_at: string; profession: string | null };
export type ActiveRow = { member_id: string; day: string }; // day is a Nairobi date "YYYY-MM-DD"
export type PostRow = {
  id: string;
  created_at: string;
  type: string;
  category?: string | null;
  location?: string | null;
  status?: string | null;
  selected_provider_id?: string | null;
};
export type AppRow = { post_id: string | null; created_at: string };

const EAT = 3 * 3600_000;
const dayStartOf = (d: string) => Date.parse(d + "T00:00:00Z") - EAT;

export function growth(
  users: UserRow[],
  active: ActiveRow[],
  posts: PostRow[],
  apps: AppRow[],
  tx: Array<{ post_id?: string | null; status: string }>,
  p: Period,
  slots: Slot[],
) {
  const members = pair(), providers = pair(), requests = pair(), offers = pair(), jobs = pair();
  for (const u of users) {
    const s = side(t(u.created_at), p);
    if (!s) continue;
    members[s] += 1;
    if (u.profession && u.profession.trim()) providers[s] += 1;
  }

  // Active members: distinct members with an active day in the period.
  const actNow = new Set<string>(), actBefore = new Set<string>();
  const perDay = new Map<string, number>();
  for (const a of active) {
    const s = side(dayStartOf(a.day) + 12 * 3600_000, p); // midday of that day
    if (s === "now") {
      actNow.add(a.member_id);
      perDay.set(a.day, (perDay.get(a.day) ?? 0) + 1);
    } else if (s === "before") actBefore.add(a.member_id);
  }
  const days = Math.max(1, Math.round((p.end - p.start) / 86_400_000));
  const avgDaily = [...perDay.values()].reduce((a, b) => a + b, 0) / days;

  // Requests: response and hire, and the time to the first response.
  const firstApp = new Map<string, number>();
  for (const a of apps) {
    if (!a.post_id) continue;
    const ms = t(a.created_at);
    const cur = firstApp.get(a.post_id);
    if (cur == null || ms < cur) firstApp.set(a.post_id, ms);
  }
  const paidPosts = new Set(tx.filter((r) => r.post_id && PAID.includes(r.status)).map((r) => r.post_id as string));

  const responded = pair(), hired = pair(), paid = pair();
  const waits: number[] = [];
  const cats = new Map<string, { requests: number; responded: number; hired: number }>();
  for (const post of posts) {
    const s = side(t(post.created_at), p);
    if (!s) continue;
    if (post.type === "offer") offers[s] += 1;
    else if (post.type === "request") {
      requests[s] += 1;
      const first = firstApp.get(post.id);
      const isHired = !!post.selected_provider_id || ["assigned", "completed", "disputed"].includes(post.status ?? "");
      if (first != null) responded[s] += 1;
      if (isHired) hired[s] += 1;
      if (paidPosts.has(post.id)) paid[s] += 1;
      if (s === "now") {
        if (first != null) waits.push(first - t(post.created_at));
        const cat = post.category || "Other";
        const c = cats.get(cat) ?? { requests: 0, responded: 0, hired: 0 };
        c.requests += 1;
        if (first != null) c.responded += 1;
        if (isHired) c.hired += 1;
        cats.set(cat, c);
      }
    } else if (post.type === "job") jobs[s] += 1;
  }

  const ratio = (a: number, b: number) => (b > 0 ? a / b : 0);
  waits.sort((a, b) => a - b);
  const medianWait = waits.length ? waits[Math.floor((waits.length - 1) / 2)] : null;

  const signups = columnsFor(users, (u) => t(u.created_at), () => [1], slots, p, 1);
  const postsDaily = columnsFor(
    posts.filter((x) => x.type === "request" || x.type === "offer"),
    (x) => t(x.created_at),
    (x) => (x.type === "request" ? [1, 0] : [0, 1]),
    slots,
    p,
    2,
  );

  return {
    members,
    providers,
    active: { now: actNow.size, before: actBefore.size },
    avgDaily,
    requests,
    offers,
    jobs,
    responded,
    hired,
    paid,
    responseRate: { now: ratio(responded.now, requests.now), before: ratio(responded.before, requests.before) },
    hireRate: { now: ratio(hired.now, requests.now), before: ratio(hired.before, requests.before) },
    medianWaitMs: medianWait,
    signups,
    postsDaily,
    categories: [...cats.entries()]
      .map(([category, c]) => ({ category, ...c, responseRate: ratio(c.responded, c.requests) }))
      .sort((a, b) => b.requests - a.requests),
  };
}

/* ─── Geography ───────────────────────────────────────────────────────────── */

export type PlaceRow = {
  id: string;
  name: string;
  kind: "city" | "town" | "area";
  parent_id: string | null;
  county: string;
  latitude: number | null;
  longitude: number | null;
  aliases: string[] | null;
  active?: boolean;
};

export type Place = { id: string; name: string; county: string; lat: number | null; lng: number | null };

/** Words too common to identify a place on their own. */
const GENERIC = new Set(["town", "city", "centre", "center", "estate", "road", "stage", "market"]);
const KIND_RANK = { area: 3, town: 2, city: 1 } as const;
const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * Match free-text locations ("Westlands, Nairobi") to the place registry.
 * The most specific match wins (an area beats its city), then the longest
 * name; areas roll up to their town or city, which is what the page groups by.
 */
export function placeMatcher(rows: PlaceRow[]) {
  const byId = new Map(rows.map((r) => [r.id, r]));
  const rollUp = (r: PlaceRow): PlaceRow => {
    let cur = r;
    for (let i = 0; i < 4 && cur.kind === "area" && cur.parent_id && byId.has(cur.parent_id); i++) cur = byId.get(cur.parent_id)!;
    return cur;
  };
  const patterns = rows
    .filter((r) => r.active !== false)
    .flatMap((r) =>
      [r.name, ...(r.aliases ?? [])]
        .map((n) => n.trim().toLowerCase())
        .filter((n) => n.length >= 3 && !GENERIC.has(n))
        .map((n) => ({ re: new RegExp(`(^|[^a-z])${esc(n)}([^a-z]|$)`), len: n.length, row: r })),
    )
    .sort((a, b) => KIND_RANK[b.row.kind] - KIND_RANK[a.row.kind] || b.len - a.len);

  const cache = new Map<string, Place | null>();
  return (text: string | null | undefined): Place | null => {
    const key = (text ?? "").trim().toLowerCase();
    if (!key) return null;
    if (cache.has(key)) return cache.get(key)!;
    const hit = patterns.find((p) => p.re.test(key));
    const top = hit ? rollUp(hit.row) : null;
    const place = top ? { id: top.id, name: top.name, county: top.county, lat: top.latitude, lng: top.longitude } : null;
    cache.set(key, place);
    return place;
  };
}

export type GeoPlace = Place & {
  requests: number;
  requestsBefore: number;
  offers: number;
  responded: number;
  hired: number;
  volume: number;
  fees: number;
};

export function geography(
  posts: PostRow[],
  apps: AppRow[],
  tx: TxRow[],
  match: (text: string | null | undefined) => Place | null,
  p: Period,
) {
  const hasApp = new Set(apps.map((a) => a.post_id).filter(Boolean) as string[]);
  const postPlace = new Map<string, Place | null>();
  const places = new Map<string, GeoPlace>();
  let unmatched = 0, located = 0;

  const get = (pl: Place) => {
    let g = places.get(pl.id);
    if (!g) {
      g = { ...pl, requests: 0, requestsBefore: 0, offers: 0, responded: 0, hired: 0, volume: 0, fees: 0 };
      places.set(pl.id, g);
    }
    return g;
  };

  for (const post of posts) {
    const pl = match(post.location);
    postPlace.set(post.id, pl);
    const s = side(t(post.created_at), p);
    if (!s) continue;
    if (s === "now") {
      if (pl) located += 1;
      else unmatched += 1;
    }
    if (!pl) continue;
    const g = get(pl);
    if (post.type === "request") {
      if (s === "before") g.requestsBefore += 1;
      else {
        g.requests += 1;
        if (hasApp.has(post.id)) g.responded += 1;
        if (post.selected_provider_id || ["assigned", "completed", "disputed"].includes(post.status ?? "")) g.hired += 1;
      }
    } else if (post.type === "offer" && s === "now") g.offers += 1;
  }
  for (const r of tx) {
    if (!PAID.includes(r.status) || side(t(r.created_at), p) !== "now" || !r.post_id) continue;
    const pl = postPlace.get(r.post_id);
    if (!pl) continue;
    const g = get(pl);
    g.volume += r.total_paid ?? 0;
    g.fees += r.fee ?? 0;
  }

  const list = [...places.values()]
    .filter((g) => g.requests + g.offers + g.volume + g.requestsBefore > 0)
    .sort((a, b) => b.requests - a.requests || b.offers - a.offers || b.volume - a.volume);

  const counties = new Map<string, { county: string; requests: number; offers: number; volume: number; places: number }>();
  for (const g of list) {
    const c = counties.get(g.county) ?? { county: g.county || "Unknown", requests: 0, offers: 0, volume: 0, places: 0 };
    c.requests += g.requests;
    c.offers += g.offers;
    c.volume += g.volume;
    c.places += 1;
    counties.set(g.county, c);
  }

  // Highlights: where demand most outruns supply, and where it grew most.
  const withDemand = list.filter((g) => g.requests >= 2);
  const underserved = [...withDemand]
    .map((g) => ({ g, gap: g.requests - g.responded }))
    .filter((x) => x.gap > 0)
    .sort((a, b) => b.gap - a.gap || a.g.responded / a.g.requests - b.g.responded / b.g.requests)[0]?.g ?? null;
  const growing = [...withDemand]
    .filter((g) => g.requests > g.requestsBefore)
    .sort((a, b) => b.requests - b.requestsBefore - (a.requests - a.requestsBefore))[0] ?? null;

  return {
    places: list,
    counties: [...counties.values()].sort((a, b) => b.requests - a.requests || b.volume - a.volume),
    located,
    unmatched,
    underserved,
    growing,
  };
}

/** "2h 15m", "35m", "3d 4h": a duration for people. */
export function durationText(ms: number | null): string {
  if (ms == null) return "None yet";
  const m = Math.max(1, Math.round(ms / 60_000));
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 48) return m % 60 ? `${h}h ${m % 60}m` : `${h}h`;
  const d = Math.floor(h / 24);
  return h % 24 ? `${d}d ${h % 24}h` : `${d}d`;
}

export const pct = (x: number) => `${Math.round(x * 100)}%`;
