import Link from "next/link";
import RestoringAccess from "@/app/dashboard/disputes/RestoringAccess";
import { Avatar } from "@/components/moderation/Badges";
import { EmptyState, ErrorState } from "@/components/moderation/States";
import { getCurrentAdmin } from "@/lib/api";
import { settle } from "@/lib/moderation-api";
import { age, fmtDateTime } from "@/lib/moderation-labels";
import {
  KIND_LABELS,
  getVerificationSummary,
  listVerifications,
  type VerificationStatus,
} from "@/lib/verifications-api";

export const dynamic = "force-dynamic";

const PATH = "/dashboard/trust-safety/verifications";
const TABS: Array<{ key: VerificationStatus; label: string }> = [
  { key: "pending", label: "Waiting" },
  { key: "approved", label: "Approved" },
  { key: "rejected", label: "Rejected" },
];

type PageProps = { searchParams: Promise<{ status?: string }> };

/**
 * Provider verifications (migration 135): ID checks for tutoring, driving,
 * security and house-cleaning work; Care checks (ID + DCI Certificate of Good
 * Conduct) for babysitting and caregiving. Oldest first — providers were told
 * they would hear back within 24 hours.
 */
export default async function VerificationsPage({ searchParams }: PageProps) {
  const sp = await searchParams;
  const tab = TABS.find((t) => t.key === sp.status) ?? TABS[0];

  const listRequest = settle(listVerifications(tab.key));
  const summaryRequest = settle(getVerificationSummary());

  const admin = await getCurrentAdmin();
  if (!admin) return <RestoringAccess />;

  const [list, summary] = await Promise.all([listRequest, summaryRequest]);

  return (
    <div className="space-y-5">
      {summary.ok && (
        <div className="grid gap-3 sm:grid-cols-3">
          <Stat label="Waiting for review" value={summary.data.pending} />
          <Stat label="Waiting over 24 h" value={summary.data.overdue} tone={summary.data.overdue > 0 ? "critical" : undefined} />
          <Stat
            label="Oldest waiting"
            value={summary.data.oldest_submitted_at ? `${age(summary.data.oldest_submitted_at)}` : "—"}
          />
        </div>
      )}

      <nav aria-label="Verification status" className="flex gap-2 flex-wrap">
        {TABS.map((t) => {
          const active = t.key === tab.key;
          return (
            <Link
              key={t.key}
              href={t.key === "pending" ? PATH : `${PATH}?status=${t.key}`}
              aria-current={active ? "page" : undefined}
              className={`px-3 py-1.5 rounded-lg text-xs font-semibold border ${
                active ? "bg-gray-900 text-on-action border-gray-900" : "bg-surface text-gray-600 border-gray-200 hover:bg-gray-50"
              }`}
            >
              {t.label}
            </Link>
          );
        })}
      </nav>

      {!list.ok ? (
        <ErrorState message={list.error} />
      ) : list.data.items.length === 0 ? (
        <EmptyState
          title={tab.key === "pending" ? "Nothing waiting" : `No ${tab.label.toLowerCase()} verifications yet`}
          body={tab.key === "pending" ? "Every provider who sent documents has had an answer." : undefined}
        />
      ) : (
        <div className="card overflow-hidden">
          <ul className="divide-y divide-gray-100">
            {list.data.items.map((v) => {
              const name = v.person?.name?.trim() || "Unnamed member";
              const overdue = v.status === "pending" && Date.now() - new Date(v.submitted_at).getTime() > 24 * 3_600_000;
              return (
                <li key={v.id}>
                  <Link href={`${PATH}/${v.id}`} className="flex items-center gap-3 px-4 py-3 hover:bg-gray-50">
                    <Avatar name={name} src={v.person?.avatar_url ?? v.person?.profile_image ?? null} />
                    <div className="min-w-0 flex-1">
                      <p className="text-[13.5px] font-semibold text-gray-900 truncate">
                        {name}
                        {v.person?.profession && <span className="font-normal text-gray-500"> · {v.person.profession}</span>}
                      </p>
                      <p className="text-[12.5px] text-gray-500 truncate">
                        {KIND_LABELS[v.kind]} · {v.document_label}
                        {v.status === "pending"
                          ? ` · sent ${age(v.submitted_at)} ago`
                          : ` · ${v.status} ${fmtDateTime(v.reviewed_at)}`}
                        {v.status === "rejected" && v.rejection_reason ? `: ${v.rejection_reason}` : ""}
                      </p>
                    </div>
                    {overdue && (
                      <span className="text-[11px] font-semibold rounded-md border border-critical-200 bg-critical-50 text-critical-700 px-1.5 py-0.5">
                        Over 24 h
                      </span>
                    )}
                    {v.kind === "care" && (
                      <span className="text-[11px] font-semibold rounded-md border border-info-200 bg-info-50 text-info-700 px-1.5 py-0.5">
                        Care
                      </span>
                    )}
                  </Link>
                </li>
              );
            })}
          </ul>
        </div>
      )}
    </div>
  );
}

function Stat({ label, value, tone }: { label: string; value: number | string; tone?: "critical" }) {
  return (
    <div className={`card px-4 py-3 ${tone === "critical" ? "border border-critical-200 bg-critical-50" : ""}`}>
      <p className="text-[11.5px] font-semibold uppercase tracking-wide text-gray-500">{label}</p>
      <p className={`text-[20px] font-bold mt-0.5 ${tone === "critical" ? "text-critical-700" : "text-gray-900"}`}>{value}</p>
    </div>
  );
}
