import Link from "next/link";
import LiveRefresh from "@/components/LiveRefresh";
import { agoLabel } from "@/lib/activity";
import { loadLiveBoard, WAITING_AFTER_HOURS, type Block } from "@/lib/live-ops";
import { fmtKes } from "@/lib/post-display";

// Right now, every time: the board re-renders every 30 s while it is open.
export const dynamic = "force-dynamic";

function Tile({ label, value, hint, failed, href }: { label: string; value: React.ReactNode; hint?: string; failed?: boolean; href?: string }) {
  const body = (
    <>
      <p className="text-[11.5px] font-medium text-gray-500">{label}</p>
      <p className="text-2xl font-semibold text-gray-900 font-tabular mt-0.5">{failed ? "—" : value}</p>
      <p className="text-[11px] text-gray-400 mt-0.5">{failed ? "Could not be read just now" : hint}</p>
    </>
  );
  return href ? (
    <Link href={href} className="card px-4 py-3 hover:border-gray-300 transition-colors">
      {body}
    </Link>
  ) : (
    <div className="card px-4 py-3">{body}</div>
  );
}

function Panel<T>({ title, block, empty, children, note }: { title: string; block: Block<T[]>; empty: string; children: (rows: T[]) => React.ReactNode; note?: string }) {
  return (
    <section className="card p-4 sm:p-5" aria-label={title}>
      <h2 className="text-[14px] font-semibold text-gray-900">{title}</h2>
      {note && <p className="text-[11.5px] text-gray-400 mt-0.5">{note}</p>}
      <div className="mt-3">
        {block.failed ? (
          <p className="text-[13px] text-gray-500">Could not be read just now — it will try again on the next refresh.</p>
        ) : block.data.length === 0 ? (
          <p className="text-[13px] text-gray-400">{empty}</p>
        ) : (
          <ul className="divide-y divide-gray-100 text-[13px]">{children(block.data)}</ul>
        )}
      </div>
    </section>
  );
}

export default async function LiveOperationsPage() {
  const b = await loadLiveBoard();
  const now = Date.parse(b.at);
  const m = b.money.data;

  return (
    <div className="space-y-5" data-testid="live-board">
      <LiveRefresh at={b.at} />

      <div className="grid gap-3 grid-cols-2 lg:grid-cols-4">
        <Tile label="In the app now" value={b.online.data.length} hint={b.activeToday.data != null ? `${b.activeToday.data} used it today` : undefined} failed={b.online.failed} href="/dashboard/users?activity=online" />
        <Tile label="Jobs in progress" value={b.jobs.data.total} hint="a provider has been chosen" failed={b.jobs.failed} href="/dashboard/marketplace/active-jobs" />
        <Tile label="Held in escrow" value={fmtKes(m.heldKes)} hint={`${m.heldCount} ${m.heldCount === 1 ? "job" : "jobs"}${m.disputedCount ? ` · ${m.disputedCount} disputed` : ""}`} failed={b.money.failed} href="/dashboard/payments/escrow" />
        <Tile label="Paying out" value={fmtKes(m.payingOutKes)} hint={`${m.payingOutCount} waiting on M-Pesa`} failed={b.money.failed} href="/dashboard/payments/escrow" />
      </div>

      <div className="grid gap-5 lg:grid-cols-2 items-start">
        <Panel
          title="Requests waiting for anyone"
          note={`Open for more than ${WAITING_AFTER_HOURS} hours with no offer yet, oldest first. Open one to call or notify matching providers.`}
          block={b.waiting}
          empty="Every recent request has had at least one offer."
        >
          {(rows) =>
            rows.map((r) => (
              <li key={r.id} className="flex items-center justify-between gap-3 py-2.5 first:pt-0 last:pb-0">
                <div className="min-w-0">
                  <Link href={`/dashboard/marketplace/requests/${r.id}`} className="font-medium text-gray-900 hover:underline">
                    {r.title?.trim() || "Untitled request"}
                  </Link>
                  <p className="text-[11.5px] text-gray-400">{[r.category, r.location].filter(Boolean).join(" · ")}</p>
                </div>
                <span className="text-[11.5px] text-caution-700 whitespace-nowrap font-tabular">{agoLabel(Date.parse(r.created_at), now)}</span>
              </li>
            ))
          }
        </Panel>

        <Panel title="Happening now" block={b.feed} empty="Nothing yet today.">
          {(rows) =>
            rows.map((f, i) => (
              <li key={`${f.at}-${i}`} className="flex items-center justify-between gap-3 py-2 first:pt-0 last:pb-0">
                {f.href ? (
                  <Link href={f.href} className={`min-w-0 truncate hover:underline ${f.kind === "payment_failed" ? "text-gray-500" : "text-gray-800"}`}>
                    {f.label}
                  </Link>
                ) : (
                  <span className="min-w-0 truncate text-gray-800">{f.label}</span>
                )}
                <span className="text-[11.5px] text-gray-400 whitespace-nowrap font-tabular">{agoLabel(Date.parse(f.at), now)}</span>
              </li>
            ))
          }
        </Panel>

        <Panel title="In the app right now" block={b.online} empty="Nobody has the app open at the moment.">
          {(rows) =>
            rows.map((p) => (
              <li key={p.id} className="py-2 first:pt-0 last:pb-0">
                <Link href={`/dashboard/users/${encodeURIComponent(p.id)}`} className="text-gray-900 hover:underline">
                  {p.name}
                </Link>
              </li>
            ))
          }
        </Panel>

        <div className="space-y-5">
          <Panel
            title="Sharing live location"
            note="Who is sharing their journey in a chat right now — where they are is never shown here."
            block={b.shares}
            empty="Nobody is sharing a live location."
          >
            {(rows) =>
              rows.map((s, i) => (
                <li key={`${s.senderId}-${i}`} className="flex items-center justify-between gap-3 py-2 first:pt-0 last:pb-0">
                  <Link href={`/dashboard/users/${encodeURIComponent(s.senderId)}`} className="text-gray-900 hover:underline">
                    {s.name}
                  </Link>
                  <span className="text-[11.5px] text-gray-400 font-tabular">
                    started {agoLabel(Date.parse(s.since), now)} · ends in {Math.max(1, Math.round((Date.parse(s.until) - now) / 60000))} min
                  </span>
                </li>
              ))
            }
          </Panel>

          <Panel title="Jobs in progress" block={{ data: b.jobs.data.latest, failed: b.jobs.failed }} empty="No job is in progress.">
            {(rows) =>
              rows.map((j) => (
                <li key={j.id} className="flex items-center justify-between gap-3 py-2 first:pt-0 last:pb-0">
                  {j.type === "request" ? (
                    <Link href={`/dashboard/marketplace/requests/${j.id}`} className="min-w-0 truncate text-gray-900 hover:underline">
                      {j.title}
                    </Link>
                  ) : (
                    <span className="min-w-0 truncate text-gray-900">{j.title}</span>
                  )}
                  <span className="text-[11.5px] text-gray-400 whitespace-nowrap font-tabular">posted {agoLabel(Date.parse(j.since), now)}</span>
                </li>
              ))
            }
          </Panel>
        </div>
      </div>
    </div>
  );
}
