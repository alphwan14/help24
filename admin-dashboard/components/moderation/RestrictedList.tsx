import Link from "next/link";
import RestoringAccess from "@/app/dashboard/disputes/RestoringAccess";
import { getCurrentAdmin } from "@/lib/api";
import { listRestricted, settle, type RestrictedRow } from "@/lib/moderation-api";
import { age, fmtDateTime, RESTRICTION_KIND_LABELS } from "@/lib/moderation-labels";
import { Avatar } from "./Badges";
import { EmptyState, ErrorState } from "./States";

const BASE = "/dashboard/trust-safety";

/**
 * Accounts under a restriction right now — read from account_restrictions,
 * the source of truth, never from the users.is_banned mirror.
 */
export default async function RestrictedList({
  kinds,
  empty,
  intro,
}: {
  kinds: Array<"suspension" | "ban" | "messaging" | "marketplace">;
  empty: { title: string; body: string };
  intro: string;
}) {
  const admin = await getCurrentAdmin();
  if (!admin) return <RestoringAccess />;

  const res = await settle(kinds.length === 1 ? listRestricted(kinds[0]) : listRestricted());
  if (!res.ok) return <ErrorState message={res.error} />;
  const rows = res.data.filter((r) => (kinds as string[]).includes(r.kind));

  return (
    <div className="space-y-4">
      <p className="text-[13px] text-gray-500">{intro}</p>
      {rows.length === 0 ? (
        <EmptyState title={empty.title} body={empty.body} />
      ) : (
        <>
          <p className="text-[13px] text-gray-500">
            {rows.length} account{rows.length === 1 ? "" : "s"}
          </p>
          <RestrictedTable rows={rows} showKind={kinds.length > 1} />
        </>
      )}
    </div>
  );
}

function RestrictedTable({ rows, showKind }: { rows: RestrictedRow[]; showKind: boolean }) {
  const now = Date.now();
  return (
    <div className="card overflow-hidden">
      <div className="overflow-x-auto">
        <table className="w-full text-sm min-w-[760px]">
          <thead>
            <tr className="border-b border-gray-100 bg-gray-50/80">
              {["Account", showKind ? "Restriction" : null, "Reason shown to them", "Since", "Ends", "Decided by", ""]
                .filter((h): h is string => h !== null)
                .map((h) => (
                  <th key={h || "open"} className="px-4 py-3 text-left text-[11px] font-semibold text-gray-400 uppercase tracking-wider whitespace-nowrap">
                    {h}
                  </th>
                ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-50 align-top">
            {rows.map((r) => {
              const endsIn = r.ends_at ? Date.parse(r.ends_at) - now : null;
              return (
                <tr key={r.id} className="hover:bg-gray-50/60">
                  <td className="px-4 py-3">
                    <Link href={`${BASE}/users/${encodeURIComponent(r.user_id)}`} className="flex items-center gap-2.5 group">
                      <Avatar name={r.user.name} src={r.user.avatar} size={28} />
                      <span className="text-[13px] font-medium text-gray-800 group-hover:underline truncate max-w-[170px]">
                        {r.user.name ?? "Unnamed account"}
                      </span>
                    </Link>
                  </td>
                  {showKind && (
                    <td className="px-4 py-3 whitespace-nowrap text-[12.5px] font-semibold text-gray-700">{RESTRICTION_KIND_LABELS[r.kind] ?? r.kind}</td>
                  )}
                  <td className="px-4 py-3 text-[12.5px] text-gray-700 max-w-[320px]">
                    <span className="line-clamp-2">{r.reason}</span>
                    <span className="block font-mono text-[10.5px] text-gray-400 mt-0.5">Ref {r.reference}</span>
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap text-[12.5px] text-gray-600" title={fmtDateTime(r.starts_at)}>
                    {age(r.starts_at, now)} ago
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap text-[12.5px]">
                    {r.ends_at ? (
                      <span className={endsIn !== null && endsIn < 86_400_000 ? "text-caution-700 font-semibold" : "text-gray-600"} title={fmtDateTime(r.ends_at)}>
                        {fmtDateTime(r.ends_at)}
                      </span>
                    ) : (
                      <span className="text-gray-400">No end date</span>
                    )}
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap text-[12.5px] text-gray-600">
                    {r.created_by_system ? "System" : r.created_by_admin?.name || r.created_by_admin?.email || "—"}
                    {r.report_id && (
                      <Link href={`${BASE}/reports/${r.report_id}`} className="block text-[11.5px] text-info-700 hover:underline">
                        From a report
                      </Link>
                    )}
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap text-right">
                    <Link href={`${BASE}/users/${encodeURIComponent(r.user_id)}`} className="text-[12.5px] font-semibold text-info-700 hover:underline">
                      Open →
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
