"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { usePathname, useRouter } from "next/navigation";
import { PERIOD_OPTIONS, type PeriodKey } from "@/lib/periods";

export const PERIOD_COOKIE = "h24_period";

/**
 * The period for Growth, Geography and Revenue: one drop-down, two groups
 * (days, months). The choice goes into the URL (shareable, back button works)
 * and a cookie, so switching tabs keeps the same period.
 */
export default function PeriodSelect({ value, range }: { value: PeriodKey; range: string }) {
  const router = useRouter();
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const [pending, startTransition] = useTransition();
  const box = useRef<HTMLDivElement>(null);
  const current = PERIOD_OPTIONS.find((o) => o.key === value)!;

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (box.current && !box.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  function choose(key: PeriodKey) {
    setOpen(false);
    document.cookie = `${PERIOD_COOKIE}=${key}; path=/dashboard; max-age=${60 * 60 * 24 * 180}; samesite=lax`;
    startTransition(() => router.push(`${pathname}?period=${key}`, { scroll: false }));
  }

  return (
    <div ref={box} className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="listbox"
        aria-expanded={open}
        className="flex items-center gap-2.5 h-10 pl-3.5 pr-3 rounded-lg border border-gray-200 bg-surface hover:border-gray-300 transition-colors text-left"
      >
        <CalendarIcon className="w-4 h-4 text-gray-400 shrink-0" />
        <span className="min-w-0">
          <span className="block text-[13px] font-semibold text-gray-900 leading-tight">{current.label}</span>
          <span className="block text-[11px] text-gray-500 leading-tight truncate">{pending ? "Loading" : range}</span>
        </span>
        <Chevron className={["w-4 h-4 text-gray-400 shrink-0 transition-transform", open ? "rotate-180" : ""].join(" ")} />
      </button>

      {open && (
        <div
          role="listbox"
          aria-label="Period"
          className="absolute right-0 z-30 mt-1.5 w-56 rounded-xl border border-gray-200 bg-surface p-1.5 shadow-lg"
        >
          {(["days", "months"] as const).map((g) => (
            <div key={g} className="py-1 first:pt-0.5">
              <p className="px-2.5 pb-1 text-[11px] font-medium text-gray-400">{g === "days" ? "Days" : "Months"}</p>
              {PERIOD_OPTIONS.filter((o) => o.group === g).map((o) => (
                <button
                  key={o.key}
                  role="option"
                  aria-selected={o.key === value}
                  onClick={() => choose(o.key)}
                  className={[
                    "w-full flex items-center justify-between h-9 px-2.5 rounded-lg text-[13.5px] transition-colors",
                    o.key === value ? "bg-gray-100 text-gray-900 font-medium" : "text-gray-700 hover:bg-gray-50",
                  ].join(" ")}
                >
                  {o.label}
                  {o.key === value && <Check className="w-4 h-4 text-gray-900" />}
                </button>
              ))}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function CalendarIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.75} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 012.25-2.25h13.5A2.25 2.25 0 0121 7.5v11.25m-18 0A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75m-18 0v-7.5A2.25 2.25 0 015.25 9h13.5A2.25 2.25 0 0121 11.25v7.5" />
    </svg>
  );
}
function Chevron({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M19.5 8.25l-7.5 7.5-7.5-7.5" />
    </svg>
  );
}
function Check({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.25} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
    </svg>
  );
}
