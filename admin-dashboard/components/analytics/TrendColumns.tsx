"use client";

import { useState } from "react";
import { kesShort, niceCeil } from "@/lib/earnings";
import { fmtKes } from "@/lib/post-display";

export type TrendSeries = { key: string; label: string; className: string };
export type TrendColumn = {
  label: string;
  short: string;
  future?: boolean;
  /** One value per series, in series order. */
  values: number[];
  /** The same slot in the previous period, summed across series. */
  previous?: number;
};

/**
 * Columns over time, stacked by series, with the previous period drawn as a
 * dashed outline behind each column. The same language as the Overview
 * Earnings panel, for any measure: money or counts.
 *
 * Tap or hover a column for its figures. Hand-built (no chart library) so it
 * stays crisp in both themes and at 360px.
 */
export default function TrendColumns({
  columns,
  series,
  money = false,
  height = "h-[170px] sm:h-[210px]",
}: {
  columns: TrendColumn[];
  series: TrendSeries[];
  money?: boolean;
  height?: string;
}) {
  const [focus, setFocus] = useState<number | null>(null);
  const fmt = (n: number) => (money ? fmtKes(n) : Math.round(n).toLocaleString("en-KE"));
  const short = (n: number) => (money ? kesShort(n) : Math.round(n).toLocaleString("en-KE"));
  const total = (c: TrendColumn) => c.values.reduce((s, v) => s + v, 0);
  const top = niceCeil(Math.max(money ? 1 : 4, ...columns.map((c) => Math.max(total(c), c.previous ?? 0))));
  const grid = [top, top / 2];
  const dense = columns.length > 16;
  const f = focus != null ? columns[focus] : null;

  return (
    <div>
      {/* Readout */}
      <div className="h-[42px] mb-1" aria-live="polite">
        {f ? (
          <div className="flex items-end justify-between gap-3 text-[12.5px]">
            <div className="min-w-0">
              <p className="font-semibold text-gray-900 truncate">{f.label}</p>
              {series.length > 1 && (
                <p className="text-gray-500 tabular-nums truncate">
                  {series.map((s, i) => (
                    <span key={s.key}>
                      {i > 0 && <span className="mx-1.5 text-gray-300" aria-hidden>|</span>}
                      {s.label} {fmt(f.values[i] ?? 0)}
                    </span>
                  ))}
                </p>
              )}
            </div>
            <div className="text-right tabular-nums shrink-0">
              <p className="font-semibold text-gray-900">{fmt(total(f))}</p>
              {f.previous != null && <p className="text-gray-400">before: {fmt(f.previous)}</p>}
            </div>
          </div>
        ) : (
          <div className="flex flex-wrap items-center gap-x-4 gap-y-1 pt-5 text-[11.5px] text-gray-500">
            {series.map((s) => (
              <span key={s.key} className="inline-flex items-center gap-1.5">
                <span className={`h-2 w-2 rounded-full ${s.className}`} aria-hidden />
                {s.label}
              </span>
            ))}
            <span className="inline-flex items-center gap-1.5 text-gray-400">
              <span className="inline-block h-2.5 w-3 rounded-t-[2px] border border-b-0 border-dashed border-gray-400" aria-hidden />
              Previous period
            </span>
          </div>
        )}
      </div>

      <div className={`relative ${height}`} onMouseLeave={() => setFocus(null)}>
        {grid.map((g) => (
          <div key={g} className="absolute inset-x-0 border-t border-dashed border-gray-200" style={{ bottom: `${(g / top) * 100}%` }} aria-hidden>
            <span className="absolute right-0 -top-[17px] text-[10.5px] text-gray-400 tabular-nums">{short(g)}</span>
          </div>
        ))}
        <div className="absolute inset-x-0 bottom-0 border-t border-gray-200" aria-hidden />

        <div className={["absolute inset-0 flex items-end", dense ? "gap-[2px]" : "gap-1 sm:gap-2"].join(" ")}>
          {columns.map((c, i) => {
            const t = total(c);
            const isFocus = focus === i;
            return (
              <button
                key={i}
                type="button"
                onMouseEnter={() => setFocus(i)}
                onFocus={() => setFocus(i)}
                onClick={() => setFocus(isFocus ? null : i)}
                aria-label={`${c.label}: ${fmt(t)}`}
                className={[
                  "relative flex-1 h-full flex flex-col justify-end rounded-sm outline-none focus-visible:ring-2 focus-visible:ring-brand-400",
                  isFocus ? "bg-gray-100/70" : "",
                ].join(" ")}
              >
                {(c.previous ?? 0) > 0 && !c.future && (
                  <span
                    className="absolute inset-x-[12%] bottom-0 rounded-t-[3px] border border-b-0 border-dashed border-gray-400/70"
                    style={{ height: `${((c.previous ?? 0) / top) * 100}%` }}
                    aria-hidden
                  />
                )}
                {c.future ? (
                  <span className="relative mx-auto h-1 w-1 rounded-full bg-gray-200" aria-hidden />
                ) : t > 0 ? (
                  <span
                    className={["relative mx-[12%] flex flex-col-reverse overflow-hidden rounded-t-[3px]", focus != null && !isFocus ? "opacity-45" : ""].join(" ")}
                    style={{ height: `max(${(t / top) * 100}%, 3px)` }}
                    aria-hidden
                  >
                    {c.values.map((v, k) => (v > 0 ? <span key={k} className={series[k]?.className} style={{ flexGrow: v }} /> : null))}
                  </span>
                ) : (
                  <span className="relative mx-[12%] h-[2px] rounded-full bg-gray-200" aria-hidden />
                )}
              </button>
            );
          })}
        </div>
      </div>

      <div className={["flex mt-1.5", dense ? "gap-[2px]" : "gap-1 sm:gap-2"].join(" ")} aria-hidden>
        {columns.map((c, i) => (
          <span key={i} className="flex-1 text-center text-[10.5px] text-gray-400 tabular-nums whitespace-nowrap overflow-visible">
            {c.short}
          </span>
        ))}
      </div>
    </div>
  );
}
