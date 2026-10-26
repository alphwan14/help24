import Link from "next/link";
import { notFound } from "next/navigation";
import { AgentControls } from "@/components/partners/AdminPartnerControls";
import { CodeCard, MethodSplit, ProgressList, SummaryTiles, WeeklyBars } from "@/components/partners/PartnerViews";
import { getCurrentAdmin } from "@/lib/api";
import { loadAccess, loadAgent, loadAgentEvents, loadMemberDetails, loadProgress } from "@/lib/partners/data";
import { KIND_LABELS, summarise, weeklyCounts } from "@/lib/partners/rules";

export const dynamic = "force-dynamic";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const EVENT_LABELS: Record<string, string> = {
  created: "Agent added",
  suspended: "Paused",
  reactivated: "Reactivated",
  invite_issued: "Invitation link issued",
  login_linked: "Accepted the invitation and set a password",
};

function fmt(iso: string): string {
  return new Date(iso).toLocaleString("en-KE", { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", timeZone: "Africa/Nairobi" });
}

/** One agent: their results, their members, their access, and what they see. */
export default async function PartnerAgentPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();
  const agent = await loadAgent(id);
  if (!agent) notFound();

  const [admin, progress, access, events] = await Promise.all([getCurrentAdmin(), loadProgress(id), loadAccess(id), loadAgentEvents(id)]);
  const details = await loadMemberDetails(progress.data.map((r) => r.member_id));
  const now = Date.now();
  const summary = summarise(progress.data, now);
  const canManage = admin?.role === "senior_admin" || admin?.role === "super_admin";
  const inviteOpen = access.invite && !access.invite.used_at && Date.parse(access.invite.expires_at) > now;

  return (
    <div className="space-y-5">
      <Link href="/dashboard/partners" className="text-[12.5px] font-semibold text-gray-500 hover:text-gray-800">← All partners</Link>

      <section className="card p-4 sm:p-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 className="text-lg font-bold text-gray-900">{agent.display_name}</h2>
            <p className="text-[13px] text-gray-500">
              {KIND_LABELS[agent.kind] ?? agent.kind} agent · code <span className="font-mono font-semibold text-gray-800">{agent.code}</span> · added{" "}
              {fmt(agent.created_at)}
            </p>
          </div>
          <span className={`badge ${agent.status === "active" ? "bg-positive-100 text-positive-700" : "bg-caution-100 text-caution-800"}`}>
            {agent.status === "active" ? "Active" : "Paused"}
          </span>
        </div>
        <dl className="mt-3 grid gap-x-6 gap-y-1 sm:grid-cols-3 text-[13px]">
          <div><dt className="text-gray-500 inline">Email </dt><dd className="inline text-gray-900">{agent.email ?? "—"}</dd></div>
          <div><dt className="text-gray-500 inline">Phone </dt><dd className="inline text-gray-900 font-tabular">{agent.phone ?? "—"}</dd></div>
          <div>
            <dt className="text-gray-500 inline">Portal </dt>
            <dd className="inline text-gray-900">{access.hasLogin ? "Signed up" : inviteOpen ? "Invited — not accepted yet" : "Not invited"}</dd>
          </div>
        </dl>
      </section>

      {canManage && <AgentControls agentId={agent.id} name={agent.display_name} status={agent.status} hasEmail={!!agent.email} />}

      <SummaryTiles summary={summary} failed={progress.failed} />
      <div className="grid gap-5 lg:grid-cols-[2fr_1fr]">
        <WeeklyBars weeks={weeklyCounts(progress.data, 8, now)} />
        <MethodSplit summary={summary} />
      </div>

      <section className="space-y-2" aria-label="Members">
        <h2 className="text-[14px] font-semibold text-gray-900">Members credited to {agent.display_name}</h2>
        <ProgressList rows={progress.data} details={details} masked={false} failed={progress.failed} now={now} memberHref={(m) => `/dashboard/users/${encodeURIComponent(m)}`} />
      </section>

      <details className="card p-4">
        <summary className="cursor-pointer text-[14px] font-semibold text-gray-900">What {agent.display_name} sees in the partner portal</summary>
        <div className="mt-4 space-y-4">
          <CodeCard code={agent.code} />
          <ProgressList rows={progress.data} details={details} masked failed={progress.failed} now={now} />
        </div>
      </details>

      <section className="card p-4" aria-label="History">
        <h2 className="text-[14px] font-semibold text-gray-900">History</h2>
        {events.failed ? (
          <p className="mt-2 text-[13px] text-gray-500">Could not be read just now.</p>
        ) : (
          <ol className="mt-2 divide-y divide-gray-100 text-[13px]">
            {events.data.map((e, i) => (
              <li key={i} className="py-2 flex flex-wrap justify-between gap-2">
                <span className="text-gray-800">
                  {EVENT_LABELS[e.action] ?? e.action}
                  {e.reason && <span className="text-gray-500"> — “{e.reason}”</span>}
                  {e.admin_email && <span className="text-gray-400"> · {e.admin_email}</span>}
                </span>
                <span className="text-[11.5px] text-gray-400 font-tabular">{fmt(e.created_at)}</span>
              </li>
            ))}
          </ol>
        )}
      </section>
    </div>
  );
}
