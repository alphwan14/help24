import { TableSkeleton } from "@/components/moderation/States";

/**
 * Route-level loading states for the dashboard sections.
 *
 * WHY EVERY SECTION HAS ONE
 * Without a `loading.tsx`, the App Router keeps the OLD page on screen until the
 * new one has finished rendering on the server — measured on production at
 * 0.8–1.9 s from Nairobi — so a click looks like it did nothing. Trust & Safety,
 * the one section that had a boundary, showed feedback in 17–43 ms on the same
 * session. A boundary also gives Next something to prefetch for dynamic routes:
 * it prefetches down to the nearest `loading.tsx` and no further.
 *
 * WHY ONE PER SECTION, NOT ONE FOR /dashboard
 * A boundary only shows its fallback when the segment directly beneath it
 * changes. A single `/dashboard/loading.tsx` would fire between sections but not
 * between Users and Active Users, which share the `users` segment.
 *
 * These render inside the section layout, so the page header stays put and only
 * the content area pulses. They carry no data and announce themselves as busy,
 * so nothing here can be mistaken for a loaded page.
 */

function Busy({ children, label }: { children: React.ReactNode; label: string }) {
  return (
    <div className="space-y-5" aria-busy="true" aria-live="polite">
      <span className="sr-only">{label}</span>
      {children}
    </div>
  );
}

function Tiles({ count = 4 }: { count?: number }) {
  return (
    <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
      {Array.from({ length: count }).map((_, i) => (
        <div key={i} className="h-[92px] rounded-xl border border-gray-200 bg-surface animate-pulse" />
      ))}
    </div>
  );
}

/** Summary tiles over a table — Users, Marketplace, Payments, Disputes, Promotion. */
export function ListRouteSkeleton({ tiles = true, rows = 8 }: { tiles?: boolean; rows?: number }) {
  return (
    <Busy label="Loading…">
      {tiles && <Tiles />}
      <TableSkeleton rows={rows} />
    </Busy>
  );
}

/** KPI tiles over chart panels — Overview and Insights. */
export function ChartsRouteSkeleton() {
  return (
    <Busy label="Loading charts…">
      <Tiles />
      <div className="grid gap-5 lg:grid-cols-2">
        <div className="card h-72 animate-pulse" />
        <div className="card h-72 animate-pulse" />
      </div>
    </Busy>
  );
}

/** Settings has no section layout, so its skeleton draws the header too. */
export function SettingsRouteSkeleton() {
  return (
    <Busy label="Loading settings…">
      <div className="space-y-2">
        <div className="h-6 w-32 rounded bg-gray-100 animate-pulse" />
        <div className="h-3 w-72 max-w-full rounded bg-gray-100 animate-pulse" />
      </div>
      <div className="card h-40 animate-pulse" />
      <div className="card h-72 animate-pulse" />
    </Busy>
  );
}
