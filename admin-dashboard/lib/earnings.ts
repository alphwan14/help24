/**
 * What Help24 has earned, for the Overview earnings chart.
 *
 * Two streams, both the platform's own money:
 *   - job fees: `transactions.fee` on transactions whose money was taken
 *     (paid, payout_pending, released; the same rule as the Overview KPIs);
 *   - promotion sales: `promotion_payments.amount_kes` with status paid.
 * Nothing here knows M-Pesa's charges, so this is earnings before those
 * costs, and the chart says so.
 *
 * Days and hours are Nairobi's (UTC+3, no daylight saving), so "today" is the
 * admin's day, not the server's.
 *
 * Pure functions; lib/earnings.test.mjs pins them.
 */

export const EAT_OFFSET_MS = 3 * 3600_000;
const DAY_MS = 86_400_000;
export const DAYS_KEPT = 60; // two 30-day windows, current and previous

export type EarningEvent = { at: string; amount: number; stream: "fees" | "promos" };
export type Bucket = { fees: number; promos: number };
export type DayBucket = Bucket & { day: string }; // "YYYY-MM-DD", Nairobi

export type EarningsSeries = {
  /** Nairobi time the series was built at, as ISO. */
  now: string;
  /** Hours 0..23 of today and yesterday, Nairobi. */
  today: Bucket[];
  yesterday: Bucket[];
  /** The last DAYS_KEPT days, oldest first, the last one being today. */
  days: DayBucket[];
};

const zero = (): Bucket => ({ fees: 0, promos: 0 });

/** Nairobi calendar day ("YYYY-MM-DD") and hour of an instant. */
export function eatParts(ms: number): { day: string; hour: number; dayStart: number } {
  const shifted = ms + EAT_OFFSET_MS;
  const dayStartShifted = Math.floor(shifted / DAY_MS) * DAY_MS;
  return {
    day: new Date(dayStartShifted).toISOString().slice(0, 10),
    hour: Math.floor((shifted - dayStartShifted) / 3600_000),
    dayStart: dayStartShifted - EAT_OFFSET_MS,
  };
}

export function buildSeries(events: EarningEvent[], now: Date = new Date()): EarningsSeries {
  const nowMs = now.getTime();
  const { dayStart: todayStart } = eatParts(nowMs);
  const yesterdayStart = todayStart - DAY_MS;
  const firstDayStart = todayStart - (DAYS_KEPT - 1) * DAY_MS;

  const today = Array.from({ length: 24 }, zero);
  const yesterday = Array.from({ length: 24 }, zero);
  const days: DayBucket[] = Array.from({ length: DAYS_KEPT }, (_, i) => ({
    day: eatParts(firstDayStart + i * DAY_MS).day,
    ...zero(),
  }));

  for (const e of events) {
    const ms = Date.parse(e.at);
    if (!Number.isFinite(ms) || ms < firstDayStart || ms > nowMs || !(e.amount > 0)) continue;
    const idx = Math.floor((ms - firstDayStart) / DAY_MS);
    days[idx][e.stream] += e.amount;
    const { hour } = eatParts(ms);
    if (ms >= todayStart) today[hour][e.stream] += e.amount;
    else if (ms >= yesterdayStart) yesterday[hour][e.stream] += e.amount;
  }

  return { now: now.toISOString(), today, yesterday, days };
}

export type PeriodId = "today" | "week" | "month";

export type PeriodView = {
  id: PeriodId;
  /** One column per hour (today) or day (week, month). */
  /** `previous` is the same slot in the previous period, by stream. */
  columns: Array<Bucket & { label: string; short: string; previous: Bucket; future: boolean; current: boolean }>;
  total: Bucket & { sum: number };
  previousTotal: Bucket & { sum: number };
  /** What the comparison is against, for the delta line. */
  versus: string;
};

const sum = (b: Bucket) => b.fees + b.promos;
const addUp = (bs: Bucket[]): Bucket => bs.reduce((t, b) => ({ fees: t.fees + b.fees, promos: t.promos + b.promos }), zero());

/** Which money to show: both streams, or one of them. */
export type StreamId = "all" | "fees" | "promos";

/** A bucket's value for the chosen stream. */
export function pick(b: Bucket, stream: StreamId): number {
  return stream === "all" ? b.fees + b.promos : b[stream];
}
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

function dayLabel(day: string): { label: string; short: string } {
  const d = new Date(day + "T00:00:00Z");
  return {
    label: `${WEEKDAYS[d.getUTCDay()]} ${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`,
    short: `${d.getUTCDate()}`,
  };
}

function hourLabel(h: number): string {
  const end = (h + 1) % 24;
  const fmt = (x: number) => `${String(x).padStart(2, "0")}:00`;
  return `${fmt(h)} to ${fmt(end)}`;
}

/**
 * One period, with its previous equal period for comparison:
 *   today: hours so far, against yesterday up to the same hour;
 *   week / month: the last 7 / 30 days, against the 7 / 30 before.
 */
export function viewFor(series: EarningsSeries, id: PeriodId): PeriodView {
  if (id === "today") {
    const { hour: nowHour } = eatParts(Date.parse(series.now));
    const columns = series.today.map((b, h) => ({
      ...b,
      label: hourLabel(h),
      short: h % 6 === 0 ? `${String(h).padStart(2, "0")}:00` : "",
      previous: series.yesterday[h],
      future: h > nowHour,
      current: h === nowHour,
    }));
    const total = series.today.reduce((t, b) => ({ fees: t.fees + b.fees, promos: t.promos + b.promos }), zero());
    const prev = addUp(series.yesterday.slice(0, nowHour + 1));
    return { id, columns, total: { ...total, sum: sum(total) }, previousTotal: { ...prev, sum: sum(prev) }, versus: "this time yesterday" };
  }

  const n = id === "week" ? 7 : 30;
  const recent = series.days.slice(-n);
  const before = series.days.slice(-2 * n, -n);
  const columns = recent.map((b, i) => {
    const { label, short } = dayLabel(b.day);
    return {
      fees: b.fees,
      promos: b.promos,
      label,
      short: id === "week" ? label.split(" ")[0] : i % 5 === 4 || i === n - 1 ? short : "",
      previous: before[i] ? { fees: before[i].fees, promos: before[i].promos } : zero(),
      future: false,
      current: i === n - 1,
    };
  });
  const total = recent.reduce((t, b) => ({ fees: t.fees + b.fees, promos: t.promos + b.promos }), zero());
  const prev = addUp(before);
  return {
    id,
    columns,
    total: { ...total, sum: sum(total) },
    previousTotal: { ...prev, sum: sum(prev) },
    versus: id === "week" ? "the 7 days before" : "the 30 days before",
  };
}

/** Change against the previous period, or null when there is nothing to compare with. */
export function change(current: number, previous: number): { pct: number; up: boolean } | null {
  if (previous <= 0) return null;
  const pct = Math.round(((current - previous) / previous) * 100);
  return { pct: Math.abs(pct), up: current >= previous };
}

/** A round axis ceiling above `max`: 1, 2 or 5 times a power of ten. */
export function niceCeil(max: number): number {
  if (max <= 0) return 100;
  const p = 10 ** Math.floor(Math.log10(max));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= max) return m * p;
  return 10 * p;
}

/** "KES 1.2k", "KES 950", "KES 3.4M": short labels for axes. */
export function kesShort(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(n >= 10_000_000 ? 0 : 1).replace(/\.0$/, "")}M`;
  if (n >= 1000) return `${(n / 1000).toFixed(n >= 10_000 ? 0 : 1).replace(/\.0$/, "")}k`;
  return String(Math.round(n));
}
