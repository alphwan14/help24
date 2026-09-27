import Link from "next/link";
import type { ReportListItem } from "@/lib/moderation-api";
import { age, ageTone, fmtDateTime, RESOLUTION_LABELS } from "@/lib/moderation-labels";
import { AccountStatusBadge, Avatar, CategoryLabel, SeverityBadge, StatusBadge, TargetTag } from "./Badges";

const BASE = "/dashboard/trust-safety";

/**
 * The report list, shared by Reports and the Moderation Queue.
 *
 * Reading order is the triage order: how serious, what is alleged, about whom,
 * how long it has waited. The reported account's standing sits next to its
 * name, and "N people" counts DISTINCT reporters with an open report — the
 * number that separates a pattern from one unhappy person.
 */
export default function ReportsTable({
  items,
  showClosedOutcome = true,
}: {
  items: ReportListItem[];
  showClosedOutcome?: boolean;
}) {
  const now = Date.now();
  return (
    <div className="card overflow-hidden">
      <div className="overflow-x-auto">
        <table className="w-full text-sm min-w-[860px]">
          <thead>
            <tr className="border-b border-gray-100 bg-gray-50/80">
              {["Report", "Severity", "Allegation", "Reported account", "Reporter", "Status", ""].map((h) => (
                <th key={h} className="px-4 py-3 text-left text-[11px] font-semibold text-gray-400 uppercase tracking-wider whitespace-nowrap">
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-50">
            {items.map((r) => {
              const open = r.status !== "resolved" && r.status !== "dismissed";
              const many = r.reported.open_reports_from_distinct_people ?? 0;
              return (
                <tr key={r.id} className="hover:bg-gray-50/60 transition-colors align-top">
                  <td className="px-4 py-3 whitespace-nowrap">
                    <Link href={`${BASE}/reports/${r.id}`} className="font-mono text-[12.5px] font-semibold text-info-700 hover:underline">
                      {r.reference}
                    </Link>
                    <p
                      className={`text-[11.5px] mt-0.5 tabular-nums ${open ? ageTone(r.created_at, now) : "text-gray-400"}`}
                      title={fmtDateTime(r.created_at)}
                    >
                      {open ? `waiting ${age(r.created_at, now)}` : fmtDateTime(r.created_at)}
                    </p>
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap">
                    <SeverityBadge severity={r.severity} />
                  </td>
                  <td className="px-4 py-3 max-w-[280px]">
                    <div className="flex items-center gap-2">
                      <CategoryLabel category={r.reason} />
                      <TargetTag type={r.target_type} />
                    </div>
                    <p className="text-[12px] text-gray-500 mt-0.5 truncate" title={r.target_label}>
                      {r.target_label}
                    </p>
                    {r.details && (
                      <p className="text-[12px] text-gray-400 mt-0.5 line-clamp-1 italic" title={r.details}>
                        &ldquo;{r.details}&rdquo;
                      </p>
                    )}
                    {r.evidence_count > 0 && (
                      <p className="text-[11px] text-gray-400 mt-0.5">
                        {r.evidence_count} attachment{r.evidence_count === 1 ? "" : "s"}
                      </p>
                    )}
                  </td>
                  <td className="px-4 py-3">
                    <Link href={`${BASE}/users/${encodeURIComponent(r.reported_user_id)}`} className="flex items-center gap-2.5 group">
                      <Avatar name={r.reported.name} src={r.reported.avatar} size={28} />
                      <span className="min-w-0">
                        <span className="block text-[13px] font-medium text-gray-800 group-hover:underline truncate max-w-[160px]">
                          {r.reported.name ?? "Unnamed account"}
                        </span>
                        <span className="flex items-center gap-1.5 mt-0.5">
                          {r.reported.account_status && r.reported.account_status !== "active" && (
                            <AccountStatusBadge status={r.reported.account_status} />
                          )}
                          {many > 1 && (
                            <span className="text-[11px] font-semibold text-critical-700" title="Distinct people with an open report about this account">
                              {many} people reporting
                            </span>
                          )}
                        </span>
                      </span>
                    </Link>
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap">
                    <span className="text-[12.5px] text-gray-600 truncate max-w-[130px] block">{r.reporter.name ?? "Unnamed account"}</span>
                    <span className="text-[11px] text-gray-400">{r.source === "api" ? "In-app report" : "Older app version"}</span>
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap">
                    <StatusBadge status={r.status} />
                    {open ? (
                      <p className="text-[11.5px] text-gray-400 mt-1">
                        {r.assigned_admin ? r.assigned_admin.name || r.assigned_admin.email : "Unassigned"}
                      </p>
                    ) : (
                      showClosedOutcome &&
                      r.resolution && <p className="text-[11.5px] text-gray-400 mt-1">{RESOLUTION_LABELS[r.resolution] ?? r.resolution}</p>
                    )}
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap text-right">
                    <Link href={`${BASE}/reports/${r.id}`} className="text-[12.5px] font-semibold text-info-700 hover:underline">
                      {open ? "Review →" : "View →"}
                    </Link>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
