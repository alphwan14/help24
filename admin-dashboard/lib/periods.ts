/**
 * Reporting periods for the Overview tabs (Growth, Geography, Revenue).
 *
 * Every period has an equal-length period before it, for the "vs before"
 * figures, and a bucket size for its charts: hours for a day, days up to
 * about four months, weeks beyond that (a year of daily columns is 365
 * hairlines).
 *
 * All boundaries are Nairobi time (UTC+3, no daylight saving). Pure;
 * lib/periods.test.mjs pins it.
 */

const EAT = 3 * 3600_000;
const DAY = 86_400_000;

export type PeriodKey =
  | "today"
  | "7d"
  | "30d"
  | "this_month"
  | "last_month"
  | "2m"
  | "3m"
  | "4m"
  | "6m"
  | "12m";

export const PERIOD_OPTIONS: Array<{ key: PeriodKey; label: string; group: "days" | "months" }> = [
  { key: "today", label: "Today", group: "days" },
  { key: "7d", label: "Last 7 days", group: "days" },
  { key: "30d", label: "Last 30 days", group: "days" },
  { key: "this_month", label: "This month", group: "months" },
  { key: "last_month", label: "Last month", group: "months" },
  { key: "2m", label: "Last 2 months", group: "months" },
  { key: "3m", label: "Last 3 months", group: "months" },
  { key: "4m", label: "Last 4 months", group: "months" },
  { key: "6m", label: "Last 6 months", group: "months" },
  { key: "12m", label: "Last 12 months", group: "months" },
];

export const DEFAULT_PERIOD: PeriodKey = "30d";

export type Bucket = "hour" | "day" | "week";

export type Period = {
  key: PeriodKey;
  label: string;
  /** [start, end) in epoch ms. */
  start: number;
  end: number;
  /** The equal-length period just before. */
  prevStart: number;
  prevEnd: number;
  bucket: Bucket;
  /** "vs the 30 days before" and so on. */
  versus: string;
};

export function isPeriodKey(v: unknown): v is PeriodKey {
  return typeof v === "string" && PERIOD_OPTIONS.some((o) => o.key === v);
}

/** Start of the Nairobi day containing `ms`. */
export function eatDayStart(ms: number): number {
  return Math.floor((ms + EAT) / DAY) * DAY - EAT;
}

/** Start of the Nairobi month containing `ms`, shifted by `delta` months. */
export function eatMonthStart(ms: number, delta = 0): number {
  const d = new Date(ms + EAT);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + delta, 1) - EAT;
}

export function resolvePeriod(key: PeriodKey, now: Date = new Date()): Period {
  const t = now.getTime();
  const label = PERIOD_OPTIONS.find((o) => o.key === key)!.label;
  const today = eatDayStart(t);
  let start: number;
  let end = t;
  let prevStart: number;
  let prevEnd: number;
  let versus: string;

  switch (key) {
    case "today":
      start = today;
      // Yesterday up to the same time of day: a morning is not judged against a whole day.
      prevStart = today - DAY;
      prevEnd = t - DAY;
      versus = "this time yesterday";
      break;
    case "7d":
    case "30d": {
      const n = key === "7d" ? 7 : 30;
      start = today - (n - 1) * DAY;
      prevStart = start - n * DAY;
      prevEnd = start;
      versus = `the ${n} days before`;
      break;
    }
    case "this_month":
      start = eatMonthStart(t);
      // Last month up to the same day and time.
      prevStart = eatMonthStart(t, -1);
      prevEnd = Math.min(prevStart + (t - start), start);
      versus = "the same days last month";
      break;
    case "last_month":
      start = eatMonthStart(t, -1);
      end = eatMonthStart(t);
      prevStart = eatMonthStart(t, -2);
      prevEnd = start;
      versus = "the month before";
      break;
    default: {
      const n = Number(key.replace("m", ""));
      // Rolling: from this date n months ago to now.
      const d = new Date(t + EAT);
      start = eatDayStart(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - n, d.getUTCDate()) - EAT) + DAY;
      prevStart = eatDayStart(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - 2 * n, d.getUTCDate()) - EAT) + DAY;
      prevEnd = start;
      versus = `the ${n} months before`;
    }
  }

  const span = end - start;
  const bucket: Bucket = key === "today" ? "hour" : span <= 125 * DAY ? "day" : "week";
  return { key, label, start, end, prevStart, prevEnd, bucket, versus };
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

export type Slot = { start: number; end: number; label: string; short: string; future: boolean };

/**
 * The chart columns of a period: hours, days or weeks (weeks start Monday),
 * each with a full label for the readout and a short one for the axis.
 */
export function slotsFor(p: Period, now: number = Date.now()): Slot[] {
  const out: Slot[] = [];
  if (p.bucket === "hour") {
    for (let h = 0; h < 24; h++) {
      const s = p.start + h * 3600_000;
      const pad = (x: number) => String(x % 24).padStart(2, "0");
      out.push({ start: s, end: s + 3600_000, label: `${pad(h)}:00 to ${pad(h + 1)}:00`, short: h % 6 === 0 ? `${pad(h)}:00` : "", future: s > now });
    }
    return out;
  }
  const step = p.bucket === "day" ? DAY : 7 * DAY;
  let s = p.start;
  if (p.bucket === "week") {
    const dow = new Date(s + EAT).getUTCDay(); // 0 Sunday
    s -= ((dow + 6) % 7) * DAY; // back to Monday
  }
  for (; s < p.end; s += step) {
    const d = new Date(s + EAT);
    const date = `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`;
    out.push({
      start: Math.max(s, p.start),
      end: Math.min(s + step, p.end),
      label: p.bucket === "day" ? `${WEEKDAYS[d.getUTCDay()]} ${date}` : `Week of ${date}`,
      short: date,
      future: false,
    });
  }
  // Thin out axis labels so they never collide: at most ~7 shown.
  const every = Math.max(1, Math.ceil(out.length / 7));
  out.forEach((sl, i) => {
    if (p.bucket === "day" && out.length <= 7) sl.short = WEEKDAYS[new Date(sl.start + EAT).getUTCDay()];
    else if (i % every !== 0 && i !== out.length - 1) sl.short = "";
  });
  return out;
}

/** Index of the slot holding `ms`, or -1. Slots are contiguous and sorted. */
export function slotIndex(slots: Slot[], ms: number): number {
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

/** "Mon 2 Nov to Sun 8 Nov" style range for headings. */
export function rangeLabel(p: Period): string {
  const f = (ms: number) => {
    const d = new Date(ms + EAT);
    return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
  };
  if (p.key === "today") return f(p.start);
  return `${f(p.start)} to ${f(p.end - 1)}`;
}
