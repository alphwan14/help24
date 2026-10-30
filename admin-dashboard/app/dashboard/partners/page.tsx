import Link from "next/link";
import { CreateAgent } from "@/components/partners/AdminPartnerControls";
import { MethodSplit, SummaryTiles, WeeklyBars } from "@/components/partners/PartnerViews";
import { getCurrentAdmin } from "@/lib/api";
import { loadAgents, loadProgress } from "@/lib/partners/data";
import { KIND_LABELS, summarise, weeklyCounts, type ProgressRow } from "@/lib/partners/rules";

// Agents are paid on these numbers: read them fresh.
export const dynamic = "force-dynamic";

/**
 * Partners, from inside the admin dashboard: every agent's results in one
 * table, and the same views the agent sees, without signing in to the
 * partner portal. Built on lib/partners — the portal's own readers and rules.
 */
export default async function PartnersPage() {
  const [admin, agents, progress] = await Promise.all([getCurrentAdmin(), loadAgents(), loadProgress()]);
  const now = Date.now();
  const all = summarise(progress.data, now);
  const byAgent = new Map<string, ProgressRow[]>();
  for (const r of progress.data) byAgent.set(r.agent_id, [...(byAgent.get(r.agent_id) ?? []), r]);
  const canManage = admin?.role === "senior_admin" || admin?.role === "super_admin";

  // Paused agents are not agents for now: they leave the table and its count,
  // and wait under a closed "Paused agents" line below it (Reactivate on the
  // agent's page). The totals still include any members they brought in.
  const active = agents.data.filter((a) => a.status === "active");
  const paused = agents.data.filter((a) => a.status !== "active");
  const rows = active
    .map((a) => ({ agent: a, s: summarise(byAgent.get(a.id) ?? [], now), last: byAgent.get(a.id)?.[0]?.claimed_at ?? null }))
    .sort((x, y) => y.s.qualified - x.s.qualified || y.s.credited - x.s.credited);

  return (
    <div className="space-y-5" data-testid="admin-partners">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-[13px] text-gray-500">
          {agents.failed ? "Agents could not be read just now." : `${active.length} ${active.length === 1 ? "agent" : "agents"}`} ·
          members qualify on 2 days of use or a post or offer in their first 14 days.
        </p>
        {canManage && <CreateAgent />}
      </div>

      <SummaryTiles summary={all} failed={progress.failed} />

      <section className="card overflow-x-auto" aria-label="Agents">
        <table className="w-full text-[13px]">
          <thead>
            <tr className="text-left text-[11.5px] text-gray-500 border-b border-gray-100">
              <th className="px-4 py-2.5 font-medium">Agent</th>
              <th className="px-4 py-2.5 font-medium">Code</th>
              <th className="px-4 py-2.5 font-medium text-right">Credited</th>
              <th className="px-4 py-2.5 font-medium text-right">Qualified</th>
              <th className="px-4 py-2.5 font-medium text-right">In progress</th>
              <th className="px-4 py-2.5 font-medium text-right">Rate</th>
              <th className="px-4 py-2.5 font-medium text-right">Last 7 days</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100">
            {rows.length === 0 ? (
              <tr>
                <td colSpan={7} className="px-4 py-6 text-center text-gray-400">
                  {agents.failed ? "Could not be read just now — reload to try again." : "No agents yet. Add the first one to give them a code."}
                </td>
              </tr>
            ) : (
              rows.map(({ agent: a, s, last }) => {
                const decided = s.qualified + s.notQualified;
                return (
                  <tr key={a.id}>
                    <td className="px-4 py-2.5">
                      <Link href={`/dashboard/partners/${a.id}`} className="font-medium text-gray-900 hover:underline">{a.display_name}</Link>
                      <p className="text-[11.5px] text-gray-400">
                        {KIND_LABELS[a.kind] ?? a.kind}
                        {last && ` · last credit ${new Date(last).toLocaleDateString("en-KE", { day: "2-digit", month: "short", timeZone: "Africa/Nairobi" })}`}
                      </p>
                    </td>
                    <td className="px-4 py-2.5 font-mono">{a.code}</td>
                    <td className="px-4 py-2.5 text-right font-tabular">{s.credited}</td>
                    <td className="px-4 py-2.5 text-right font-tabular font-semibold">{s.qualified}</td>
                    <td className="px-4 py-2.5 text-right font-tabular">{s.inProgress}</td>
                    <td className="px-4 py-2.5 text-right font-tabular">{decided ? `${Math.round((s.qualified / decided) * 100)}%` : "—"}</td>
                    <td className="px-4 py-2.5 text-right font-tabular">{s.thisWeek}</td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </section>

      {paused.length > 0 && (
        <details className="text-[12px] text-gray-400" data-testid="paused-agents">
          <summary className="cursor-pointer select-none hover:text-gray-600">Paused agents ({paused.length})</summary>
          <ul className="mt-2 divide-y divide-gray-100 rounded-lg border border-gray-100">
            {paused.map((a) => (
              <li key={a.id} className="flex items-center justify-between gap-3 px-3 py-2">
                <span className="min-w-0 truncate text-gray-500">
                  {a.display_name} · {KIND_LABELS[a.kind] ?? a.kind} · <span className="font-mono">{a.code}</span>
                </span>
                <Link href={`/dashboard/partners/${a.id}`} className="shrink-0 font-semibold text-gray-600 hover:text-gray-900 hover:underline">
                  Open
                </Link>
              </li>
            ))}
          </ul>
        </details>
      )}

      <div className="grid gap-5 lg:grid-cols-[2fr_1fr]">
        <WeeklyBars weeks={weeklyCounts(progress.data, 8, now)} />
        <MethodSplit summary={all} />
      </div>
    </div>
  );
}
