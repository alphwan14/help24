import Link from "next/link";

/** Nothing matched — said plainly, with the way out when there is one. */
export function EmptyState({ title, body, action }: { title: string; body?: string; action?: { href: string; label: string } }) {
  return (
    <div className="card px-6 py-12 text-center">
      <div className="mx-auto w-10 h-10 rounded-full bg-gray-100 flex items-center justify-center text-gray-400">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} className="w-5 h-5">
          <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
      </div>
      <p className="text-sm font-semibold text-gray-800 mt-3">{title}</p>
      {body && <p className="text-[13px] text-gray-500 mt-1 max-w-sm mx-auto">{body}</p>}
      {action && (
        <Link href={action.href} className="inline-block mt-4 text-[13px] font-semibold text-info-700 hover:underline">
          {action.label}
        </Link>
      )}
    </div>
  );
}

/**
 * A read that failed. Never rendered as an empty list: "no reports" and "we
 * could not load the reports" are different facts, and only one of them is
 * safe to act on.
 */
export function ErrorState({ message }: { message: string }) {
  return (
    <div className="card p-5 border border-critical-200 bg-critical-50">
      <p className="text-sm font-semibold text-critical-700">Couldn&apos;t load this</p>
      <p className="text-[13px] text-critical-700/90 mt-1">{message}</p>
      <p className="text-[12px] text-gray-500 mt-2">
        Nothing is shown rather than a partial or empty view. Refresh to try again.
      </p>
    </div>
  );
}

export function Pagination({
  total,
  limit,
  offset,
  hrefFor,
}: {
  total: number;
  limit: number;
  offset: number;
  hrefFor: (offset: number) => string;
}) {
  if (total <= limit) return null;
  const from = offset + 1;
  const to = Math.min(offset + limit, total);
  const prev = Math.max(0, offset - limit);
  const next = offset + limit;
  return (
    <div className="flex items-center justify-between text-[13px] text-gray-500">
      <span className="tabular-nums">
        {from}–{to} of {total}
      </span>
      <div className="flex gap-2">
        {offset > 0 ? (
          <Link href={hrefFor(prev)} className="px-3 py-1.5 rounded-lg border border-gray-200 hover:bg-gray-50 font-medium text-gray-700">
            Previous
          </Link>
        ) : (
          <span className="px-3 py-1.5 rounded-lg border border-gray-100 text-gray-300">Previous</span>
        )}
        {next < total ? (
          <Link href={hrefFor(next)} className="px-3 py-1.5 rounded-lg border border-gray-200 hover:bg-gray-50 font-medium text-gray-700">
            Next
          </Link>
        ) : (
          <span className="px-3 py-1.5 rounded-lg border border-gray-100 text-gray-300">Next</span>
        )}
      </div>
    </div>
  );
}

/** Two-column skeleton for the report and account pages. */
export function DetailSkeleton() {
  const block = (h: string) => <div className={`card ${h} animate-pulse`} />;
  return (
    <div className="space-y-5" aria-busy="true" aria-live="polite">
      <div className="space-y-2">
        <div className="h-3 w-32 rounded bg-gray-100 animate-pulse" />
        <div className="h-6 w-64 rounded bg-gray-100 animate-pulse" />
        <div className="h-3 w-96 max-w-full rounded bg-gray-100 animate-pulse" />
      </div>
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_340px]">
        <div className="space-y-5">
          {block("h-48")}
          {block("h-64")}
        </div>
        <div className="space-y-5">
          {block("h-80")}
          {block("h-40")}
        </div>
      </div>
    </div>
  );
}

/** Skeleton rows for route-level loading states. */
export function TableSkeleton({ rows = 8 }: { rows?: number }) {
  return (
    <div className="card overflow-hidden" aria-busy="true" aria-live="polite">
      <div className="h-10 bg-gray-50 border-b border-gray-100" />
      <div className="divide-y divide-gray-50">
        {Array.from({ length: rows }).map((_, i) => (
          <div key={i} className="flex items-center gap-4 px-4 py-3.5">
            <div className="h-3 w-20 rounded bg-gray-100 animate-pulse" />
            <div className="h-3 w-28 rounded bg-gray-100 animate-pulse" />
            <div className="h-5 w-16 rounded-full bg-gray-100 animate-pulse" />
            <div className="h-3 flex-1 rounded bg-gray-100 animate-pulse" />
            <div className="h-5 w-20 rounded-full bg-gray-100 animate-pulse" />
          </div>
        ))}
      </div>
    </div>
  );
}
