"use client";

import { useEffect, useMemo, useState } from "react";
import { change, kesShort, niceCeil, pick, viewFor, type EarningsSeries, type PeriodId, type StreamId } from "@/lib/earnings";
import { fmtKes } from "@/lib/post-display";

const PERIODS: Array<{ id: PeriodId; label: string }> = [
  { id: "today", label: "Today" },
  { id: "week", label: "Week" },
  { id: "month", label: "Month" },
];
const PERIOD_KEY = "help24-earnings-period";

const STREAMS: Array<{ id: StreamId; label: string; swatch: string }> = [
  { id: "all", label: "All earnings", swatch: "bg-gradient-to-r from-brand-600 from-50% to-accent-500 to-50%" },
  { id: "fees", label: "Job fees", swatch: "bg-brand-600" },
  { id: "promos", label: "Promotions", swatch: "bg-accent-500" },
];

/**
 * What Help24 earned, today, this week or this month.
 *
 * Built to answer one question at a glance: how much did we make, and is it
 * more or less than before. So the number leads, the change against the
 * previous equal period sits beside it, and the chart below shows where in
 * the period the money came from:
 *
 *   - two streams, job fees (ink) and promotion sales (amber). The three
 *     cards under the number are both the legend and the switch: All shows
 *     the columns stacked by stream, or pick one stream to see it alone,
 *     with its own total and its own comparison;
 *   - each column is an hour (today) or a day (week, month);
 *   - a dashed outline behind each column is the same slot in the previous
 *     period, so "better than last week" reads without a second chart;
 *   - today's hours still to come are drawn as an empty track, so a quiet
 *     morning does not look like a quiet day.
 *
 * Tap or hover a column for its figures. Hand-built (no chart library): the
 * shapes are simple, and this keeps it crisp in both themes and at 360px.
 */
export default function EarningsPanel({ series }: { series: EarningsSeries | null }) {
  const [period, setPeriod] = useState<PeriodId>("today");
  const [focus, setFocus] = useState<number | null>(null);
  const [stream, setStream] = useState<StreamId>("all");

  useEffect(() => {
    try {
      const saved = localStorage.getItem(PERIOD_KEY);
      if (saved === "today" || saved === "week" || saved === "month") setPeriod(saved);
    } catch {
      /* default it is */
    }
  }, []);

  function choose(p: PeriodId) {
    setPeriod(p);
    setFocus(null);
    try {
      localStorage.setItem(PERIOD_KEY, p);
    } catch {
      /* still switched for this visit */
    }
  }

  const view = useMemo(() => (series ? viewFor(series, period) : null), [series, period]);

  if (!series || !view) {
    return (
      <section className="rounded-xl border border-gray-200 bg-surface p-5">
        <h2 className="text-[14px] font-semibold text-gray-900">Earnings</h2>
        <p className="mt-1 text-[13px] text-gray-500">
          Earnings could not be read just now. Nothing is shown rather than a figure that may be wrong. Reload to try
          again.
        </p>
      </section>
    );
  }

  const current = pick(view.total, stream);
  const previous = pick(view.previousTotal, stream);
  const delta = change(current, previous);
  const top = niceCeil(Math.max(1, ...view.columns.map((c) => Math.max(pick(c, stream), pick(c.previous, stream)))));
  const grid = [top, top / 2];
  const focused = focus != null ? view.columns[focus] : null;
  const what = stream === "all" ? "earnings" : stream === "fees" ? "job fees" : "promotion sales";
  const dense = view.columns.length > 12;

  return (
    <section aria-labelledby="earnings-heading" className="rounded-xl border border-gray-200 bg-surface">
      {/* Head: title and period */}
      <div className="flex items-center justify-between gap-3 px-4 sm:px-6 pt-4 sm:pt-5">
        <h2 id="earnings-heading" className="text-[13px] font-semibold text-gray-500">
          Earnings
        </h2>
        <div role="tablist" aria-label="Period" className="inline-flex rounded-lg bg-gray-100 p-0.5">
          {PERIODS.map((p) => (
            <button
              key={p.id}
              role="tab"
              aria-selected={period === p.id}
              onClick={() => choose(p.id)}
              className={[
                "px-3 sm:px-3.5 h-8 rounded-md text-[13px] font-medium transition-colors",
                period === p.id ? "bg-surface text-gray-900 shadow-sm" : "text-gray-500 hover:text-gray-800",
              ].join(" ")}
            >
              {p.label}
            </button>
          ))}
        </div>
      </div>

      {/* The number, and how it compares */}
      <div className="px-4 sm:px-6 pt-3">
        <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <p className="text-[32px] sm:text-[40px] font-semibold tracking-tight leading-none text-gray-900 tabular-nums">
            {fmtKes(current)}
          </p>
          {delta && (
            <span
              className={[
                "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[12.5px] font-semibold tabular-nums",
                delta.up ? "bg-positive-100 text-positive-700" : "bg-critical-100 text-critical-700",
              ].join(" ")}
            >
              <Arrow up={delta.up} />
              {delta.pct}%
            </span>
          )}
        </div>
        <p className="mt-1.5 text-[13px] text-gray-500">
          {delta
            ? `${stream === "all" ? "" : `${what.charAt(0).toUpperCase() + what.slice(1)} `}${delta.up ? (stream === "all" ? "Up" : "up") : stream === "all" ? "Down" : "down"} on ${view.versus} (${fmtKes(previous)})`
            : current > 0
              ? `No ${what} in ${view.versus} to compare with`
              : `No ${what} yet ${view.id === "today" ? "today" : "in this period"}`}
        </p>

        {/* The streams: legend and switch in one */}
        <div role="radiogroup" aria-label="Which earnings" className="mt-4 grid grid-cols-3 gap-2">
          {STREAMS.map((st) => {
            const value = pick(view.total, st.id);
            const share = view.total.sum > 0 && st.id !== "all" ? Math.round((value / view.total.sum) * 100) : null;
            const on = stream === st.id;
            return (
              <button
                key={st.id}
                role="radio"
                aria-checked={on}
                onClick={() => {
                  setStream(st.id);
                  setFocus(null);
                }}
                className={[
                  "text-left rounded-lg border px-2.5 py-2 sm:px-3 transition-colors min-w-0",
                  on ? "border-gray-900 bg-gray-50" : "border-gray-200 hover:border-gray-300",
                ].join(" ")}
              >
                <span className="flex items-center gap-1.5 text-[11.5px] sm:text-[12px] text-gray-500 truncate">
                  <span className={`h-2 w-2 shrink-0 rounded-full ${st.swatch}`} aria-hidden />
                  {st.label}
                </span>
                <span className="mt-0.5 flex items-baseline gap-1.5 min-w-0">
                  <span className="text-[13px] sm:text-[14px] font-semibold text-gray-900 tabular-nums truncate">
                    {fmtKes(value)}
                  </span>
                  {share != null && <span className="hidden sm:inline text-[11.5px] text-gray-400 tabular-nums">{share}%</span>}
                </span>
              </button>
            );
          })}
        </div>
      </div>

      {/* The columns */}
      <div className="relative px-4 sm:px-6 pt-6 pb-2">
        {/* Readout for the column under the finger or pointer */}
        <div className="h-[46px] mb-1" aria-live="polite">
          {focused ? (
            <div className="flex items-end justify-between gap-3 text-[12.5px]">
              <div>
                <p className="font-semibold text-gray-900">{focused.label}</p>
                {stream === "all" ? (
                  <p className="text-gray-500 tabular-nums">
                    Fees {fmtKes(focused.fees)}
                    <span className="mx-2 text-gray-300" aria-hidden>
                      |
                    </span>
                    Promotions {fmtKes(focused.promos)}
                  </p>
                ) : (
                  <p className="text-gray-500">{stream === "fees" ? "Job fees" : "Promotions"}</p>
                )}
              </div>
              <div className="text-right tabular-nums">
                <p className="font-semibold text-gray-900">{fmtKes(pick(focused, stream))}</p>
                <p className="text-gray-400">before: {fmtKes(pick(focused.previous, stream))}</p>
              </div>
            </div>
          ) : (
            <p className="text-[12px] text-gray-400 pt-6">
              Tap or hover a column for its figures
            </p>
          )}
        </div>

        <div className="relative h-[150px] sm:h-[190px]" onMouseLeave={() => setFocus(null)}>
          {/* Grid: two quiet lines with their values */}
          {grid.map((g) => (
            <div
              key={g}
              className="absolute inset-x-0 border-t border-dashed border-gray-200"
              style={{ bottom: `${(g / top) * 100}%` }}
              aria-hidden
            >
              <span className="absolute right-0 -top-[18px] text-[10.5px] text-gray-400 tabular-nums">
                {kesShort(g)}
              </span>
            </div>
          ))}
          <div className="absolute inset-x-0 bottom-0 border-t border-gray-200" aria-hidden />

          <div className={["absolute inset-0 flex items-end", dense ? "gap-[3px]" : "gap-1.5 sm:gap-2.5"].join(" ")}>
            {view.columns.map((c, i) => {
              const total = pick(c, stream);
              const prev = pick(c.previous, stream);
              const h = (total / top) * 100;
              const prevH = (prev / top) * 100;
              const isFocus = focus === i;
              return (
                <button
                  key={i}
                  type="button"
                  onMouseEnter={() => setFocus(i)}
                  onFocus={() => setFocus(i)}
                  onClick={() => setFocus(isFocus ? null : i)}
                  aria-label={`${c.label}: ${fmtKes(total)} in ${what}${c.future ? ", still to come" : ""}`}
                  className={[
                    "group relative flex-1 h-full flex flex-col justify-end rounded-sm outline-none",
                    "focus-visible:ring-2 focus-visible:ring-brand-400",
                    isFocus ? "bg-gray-100/70" : "",
                  ].join(" ")}
                >
                  {/* The same slot in the previous period */}
                  {prev > 0 && !c.future && (
                    <span
                      className="absolute inset-x-[12%] bottom-0 rounded-t-[3px] border border-b-0 border-dashed border-gray-400/70"
                      style={{ height: `${prevH}%` }}
                      aria-hidden
                    />
                  )}
                  {c.future ? (
                    <span className="relative mx-auto mb-0 h-1 w-1 rounded-full bg-gray-200" aria-hidden />
                  ) : total > 0 ? (
                    <span
                      className={[
                        "relative mx-[12%] flex flex-col overflow-hidden rounded-t-[3px] transition-opacity",
                        focus != null && !isFocus ? "opacity-45" : "",
                      ].join(" ")}
                      style={{ height: `max(${h}%, 3px)` }}
                      aria-hidden
                    >
                      {stream !== "fees" && c.promos > 0 && <span className="bg-accent-500" style={{ flexGrow: c.promos }} />}
                      {stream !== "promos" && c.fees > 0 && <span className="bg-brand-600" style={{ flexGrow: c.fees }} />}
                    </span>
                  ) : (
                    <span className="relative mx-[12%] h-[2px] rounded-full bg-gray-200" aria-hidden />
                  )}
                  {c.current && view.id === "today" && (
                    <span className="absolute -top-0.5 left-1/2 -translate-x-1/2 h-full w-px bg-accent-500/50" aria-hidden />
                  )}
                </button>
              );
            })}
          </div>
        </div>

        {/* Axis labels */}
        <div className={["flex mt-1.5", dense ? "gap-[3px]" : "gap-1.5 sm:gap-2.5"].join(" ")} aria-hidden>
          {view.columns.map((c, i) => (
            <span
              key={i}
              className={[
                "flex-1 text-center text-[10.5px] tabular-nums whitespace-nowrap",
                c.current ? "text-gray-900 font-semibold" : "text-gray-400",
              ].join(" ")}
            >
              {c.current && view.id === "today" ? "Now" : c.short}
            </span>
          ))}
        </div>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-2 border-t border-gray-200 px-4 sm:px-6 py-3 text-[11.5px] text-gray-400">
        <span className="flex items-center gap-2">
          <span className="inline-block h-2.5 w-3 rounded-t-[2px] border border-b-0 border-dashed border-gray-400" aria-hidden />
          Previous period
        </span>
        <span>Fees on paid jobs and promotion sales, before M-Pesa charges. Nairobi time.</span>
      </div>
    </section>
  );
}

function Arrow({ up }: { up: boolean }) {
  return (
    <svg viewBox="0 0 12 12" className={["h-3 w-3", up ? "" : "rotate-180"].join(" ")} aria-hidden>
      <path d="M6 2.5 10 7.5H2z" fill="currentColor" />
    </svg>
  );
}
