import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import AccountActionPanel from "@/components/moderation/AccountActionPanel";
import { ActiveRestrictions, AccountHeader, SignalsGrid } from "@/components/moderation/AccountPanels";
import ContentActionButton from "@/components/moderation/ContentActionButton";
import Ledger from "@/components/moderation/Ledger";
import NoteComposer from "@/components/moderation/NoteComposer";
import ReportsTable from "@/components/moderation/ReportsTable";
import { ErrorState } from "@/components/moderation/States";
import Timeline from "@/components/moderation/Timeline";
import { getCurrentAdmin } from "@/lib/api";
import { getUserModeration, settle, type RestrictionRecord } from "@/lib/moderation-api";
import { fmtDate, fmtDateTime, humanise, RESTRICTION_KIND_LABELS } from "@/lib/moderation-labels";

export const dynamic = "force-dynamic";

const BASE = "/dashboard/trust-safety";
const USER_ID = /^[A-Za-z0-9_-]{1,128}$/;

type PageProps = { params: Promise<{ id: string }> };

/**
 * One account's whole Trust & Safety record: who they are, what the platform
 * shows they have done, what has been alleged, and every decision taken —
 * enough to answer "what has this person done before?" without a query.
 */
export default async function AccountModerationPage({ params }: PageProps) {
  const { id: raw } = await params;
  const id = decodeURIComponent(raw);
  if (!USER_ID.test(id)) notFound();

  const admin = await getCurrentAdmin();
  if (!admin) redirect(`${BASE}/queue`);

  const res = await settle(getUserModeration(id));
  if (!res.ok) {
    if (res.status === 404 || res.status === 400) notFound();
    return <ErrorState message={res.error} />;
  }
  const p = res.data;
  const name = p.user?.name?.trim() || "Unnamed account";
  const decisions = p.ledger.filter((e) => e.action_type !== "note_added");
  const notes = p.ledger.filter((e) => e.action_type === "note_added");
  // recent_posts is capped at 25; past that the count would be a guess.
  const openListings = p.recent_posts.filter((x) => !x.archived_at && x.status === "open").length;

  return (
    <div className="space-y-5">
      <Link href={`${BASE}/queue`} className="text-[12.5px] font-semibold text-gray-500 hover:text-gray-800">
        ← Moderation queue
      </Link>

      <div className="grid gap-5 items-start lg:grid-cols-[minmax(0,1fr)_340px] lg:grid-rows-[auto_1fr]">
        <div className="space-y-5 min-w-0 lg:col-start-1 lg:row-start-1">
          <section className="card p-4 sm:p-5 space-y-4">
            <AccountHeader summary={p} />
            <ActiveRestrictions summary={p} />
          </section>
        </div>

        <aside className="space-y-5 min-w-0 lg:col-start-2 lg:row-start-1 lg:row-span-2">
          <AccountActionPanel
            user={{ id, name, status: p.account.status, isAdmin: p.user?.role === "admin" }}
            admin={{ role: admin.role }}
            active={p.account.active_restrictions.map((r) => ({ id: r.id, kind: r.kind, reference: r.reference, ends_at: r.ends_at }))}
            openListings={p.recent_posts.length < 25 ? openListings : undefined}
          />
          <section className="card p-4">
            <h3 className="text-[13px] font-semibold text-gray-900 mb-3">Internal notes</h3>
            <Ledger entries={notes} empty="No notes yet." />
            <div className={notes.length ? "mt-4" : "mt-2"}>
              <NoteComposer userId={id} />
            </div>
          </section>
        </aside>

        <div className="space-y-5 min-w-0 lg:col-start-1 lg:row-start-2">
          <section className="card p-4 sm:p-5">
            <h3 className="text-[14px] font-semibold text-gray-900 mb-3">Signals</h3>
            <SignalsGrid s={p.signals} />
          </section>

          <section className="card p-4 sm:p-5">
            <h3 className="text-[14px] font-semibold text-gray-900 mb-3">Moderation history</h3>
            <Ledger entries={decisions} empty="No action has ever been taken on this account." />
          </section>

          <section className="card p-4 sm:p-5">
            <h3 className="text-[14px] font-semibold text-gray-900 mb-3">Restrictions, including ended ones</h3>
            <RestrictionHistory rows={p.restrictions} />
          </section>

          <section className="space-y-2">
            <div className="flex items-center justify-between">
              <h3 className="text-[14px] font-semibold text-gray-900">Reports about {name}</h3>
              {p.reports_received.length > 0 && (
                <Link href={`${BASE}/reports?reported_user_id=${encodeURIComponent(id)}`} className="text-[12.5px] font-semibold text-info-700 hover:underline">
                  Filter the report list →
                </Link>
              )}
            </div>
            {p.reports_received.length === 0 ? (
              <p className="card p-4 text-[13px] text-gray-400">Nobody has reported this account.</p>
            ) : (
              <ReportsTable items={p.reports_received} />
            )}
          </section>

          {p.reports_made.length > 0 && (
            <section className="space-y-2">
              <h3 className="text-[14px] font-semibold text-gray-900">Reports {name} filed</h3>
              <ReportsTable items={p.reports_made} />
            </section>
          )}

          <section className="card p-4 sm:p-5">
            <h3 className="text-[14px] font-semibold text-gray-900 mb-3">Recent listings</h3>
            {p.recent_posts.length === 0 ? (
              <p className="text-[13px] text-gray-400">No listings.</p>
            ) : (
              <ul className="divide-y divide-gray-100">
                {p.recent_posts.map((post) => (
                  <li key={post.id} className="py-2.5 flex flex-wrap items-center justify-between gap-2">
                    <div className="min-w-0">
                      <p className="text-[13px] font-medium text-gray-800 truncate">{post.title}</p>
                      <p className="text-[11.5px] text-gray-400">
                        {humanise(post.type)} · {humanise(post.status)} · {fmtDate(post.created_at)}
                        {post.archived_by === "moderation" ? " · hidden by moderation" : post.archived_at ? " · removed by owner" : ""}
                      </p>
                    </div>
                    {post.archived_by === "moderation" ? (
                      <ContentActionButton type="post" id={post.id} action="restore" ownerUserId={id} compact />
                    ) : !post.archived_at && post.status === "open" ? (
                      <ContentActionButton type="post" id={post.id} action="remove" ownerUserId={id} compact />
                    ) : null}
                  </li>
                ))}
              </ul>
            )}
          </section>

          <section className="card p-4 sm:p-5">
            <h3 className="text-[14px] font-semibold text-gray-900 mb-3">Recent applications</h3>
            {p.recent_applications.length === 0 ? (
              <p className="text-[13px] text-gray-400">No applications.</p>
            ) : (
              <ul className="divide-y divide-gray-100">
                {p.recent_applications.map((a) => (
                  <li key={a.id} className="py-2.5">
                    <p className="text-[13px] text-gray-800">
                      On <span className="font-medium">{a.posts?.title ?? "a listing"}</span>
                      <span className="text-gray-400"> · {fmtDate(a.created_at)}</span>
                    </p>
                    {a.message && <p className="text-[12.5px] text-gray-500 line-clamp-2 whitespace-pre-line">{a.message}</p>}
                  </li>
                ))}
              </ul>
            )}
          </section>

          <section className="card p-4 sm:p-5">
            <h3 className="text-[14px] font-semibold text-gray-900 mb-1">Timeline</h3>
            <p className="text-[11.5px] text-gray-400 mb-3">Newest first.</p>
            <Timeline events={p.timeline} />
          </section>
        </div>
      </div>
    </div>
  );
}

function RestrictionHistory({ rows }: { rows: RestrictionRecord[] }) {
  if (rows.length === 0) return <p className="text-[13px] text-gray-400">None, ever.</p>;
  return (
    <div className="overflow-x-auto -mx-1">
      <table className="w-full text-[12.5px] min-w-[620px]">
        <thead>
          <tr className="text-left text-[10.5px] font-semibold uppercase tracking-wide text-gray-400">
            <th className="px-1 py-1.5">Kind</th>
            <th className="px-1 py-1.5">Reason shown to them</th>
            <th className="px-1 py-1.5">From</th>
            <th className="px-1 py-1.5">Until</th>
            <th className="px-1 py-1.5">Outcome</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 align-top">
          {rows.map((r) => (
            <tr key={r.id}>
              <td className="px-1 py-2 whitespace-nowrap">
                <span className="font-semibold text-gray-800">{RESTRICTION_KIND_LABELS[r.kind] ?? r.kind}</span>
                <span className="block font-mono text-[10.5px] text-gray-400">{r.reference}</span>
              </td>
              <td className="px-1 py-2 text-gray-700 max-w-[260px]">
                <span className="line-clamp-3 whitespace-pre-line">{r.reason}</span>
                <span className="block text-[11px] text-gray-400 mt-0.5">
                  {r.created_by_system ? "System" : r.created_by_admin?.email ?? "Unknown admin"}
                  {r.report_id && (
                    <>
                      {" · "}
                      <Link href={`${BASE}/reports/${r.report_id}`} className="text-info-700 hover:underline">
                        report
                      </Link>
                    </>
                  )}
                </span>
              </td>
              <td className="px-1 py-2 whitespace-nowrap text-gray-600">{fmtDateTime(r.starts_at)}</td>
              <td className="px-1 py-2 whitespace-nowrap text-gray-600">{r.ends_at ? fmtDateTime(r.ends_at) : "No end"}</td>
              <td className="px-1 py-2 text-gray-600">
                {r.active ? (
                  <span className="badge bg-caution-100 text-caution-700">In force</span>
                ) : r.lifted_at ? (
                  <>
                    Lifted {fmtDateTime(r.lifted_at)}
                    <span className="block text-[11px] text-gray-400">
                      {r.lifted_by_admin?.email ?? "admin"}
                      {r.lift_reason ? ` — ${r.lift_reason}` : ""}
                    </span>
                  </>
                ) : (
                  "Ended"
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
