/**
 * Daily series for the Overview charts.
 *
 * The overview data only has rows for days on which something happened, keyed
 * "MM-DD". Charted as-is, a quiet week vanishes from the axis and six bars
 * spread across the width look like steady activity. These fill every day of
 * the window with zero and label each one as people read dates ("13 Oct").
 */

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** The last `days` UTC dates, oldest first, as "MM-DD" keys with readable labels. */
export function lastDays(days: number, now: Date = new Date()): Array<{ key: string; label: string }> {
  const out: Array<{ key: string; label: string }> = [];
  const end = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(end - i * 86_400_000);
    const mm = String(d.getUTCMonth() + 1).padStart(2, "0");
    const dd = String(d.getUTCDate()).padStart(2, "0");
    out.push({ key: `${mm}-${dd}`, label: `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}` });
  }
  return out;
}

/**
 * Every day of the window, in order, with the row for that day or zeros.
 * `date` on the result is the readable label; rows outside the window drop.
 */
export function fillDays<T extends { date: string }>(
  rows: T[],
  zero: Omit<T, "date">,
  days = 30,
  now: Date = new Date(),
): T[] {
  const byKey = new Map(rows.map((r) => [r.date, r]));
  return lastDays(days, now).map(({ key, label }) => {
    const row = byKey.get(key);
    return { ...zero, ...(row ?? {}), date: label } as T;
  });
}
