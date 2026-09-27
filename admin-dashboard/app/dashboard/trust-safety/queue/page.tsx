import Link from "next/link";
import RestoringAccess from "@/app/dashboard/disputes/RestoringAccess";
import ReportFilters from "@/components/moderation/ReportFilters";
import ReportsTable from "@/components/moderation/ReportsTable";
import SummaryStrip from "@/components/moderation/SummaryStrip";
import { EmptyState, ErrorState, Pagination } from "@/components/moderation/States";
import { getCurrentAdmin } from "@/lib/api";
import { getModerationSummary, listReports, settle } from "@/lib/moderation-api";
import { hrefWith, param, reportApiQuery, reportFilterValues, type SearchParams } from "@/lib/moderation-query";

export const dynamic = "force-dynamic";

const PATH = "/dashboard/trust-safety/queue";

/**
 * The work queue: every report still awaiting a decision, most serious first
 * and, within a severity, oldest first — so nothing serious waits behind
 * something recent.
 */
const SCOPES = [
  { key: "all", label: "All open", status: "open" },
  { key: "unassigned", label: "Unassigned", status: "open", assigned: "none" },
  { key: "mine", label: "Assigned to me", status: "open", assigned: "me" },
  { key: "new", label: "New", status: "new" },
  { key: "under_review", label: "Under review", status: "under_review" },
  { key: "action_required", label: "Action required", status: "action_required" },
] as const;

type PageProps = { searchParams: Promise<SearchParams> };

export default async function QueuePage({ searchParams }: PageProps) {
  const admin = await getCurrentAdmin();
  if (!admin) return <RestoringAccess />;

  const sp = await searchParams;
  const scope = SCOPES.find((s) => s.key === param(sp, "scope")) ?? SCOPES[0];
  const query = reportApiQuery(sp, {
    status: scope.status,
    assigned: "assigned" in scope ? scope.assigned : undefined,
    sort: "queue",
  });

  const [summary, page] = await Promise.all([settle(getModerationSummary()), settle(listReports(query))]);
  const values = reportFilterValues(sp);
  const filtered = !!(values.q || values.severity || values.category || values.target_type);

  return (
    <div className="space-y-5">
      <SummaryStrip summary={summary} />

      <nav aria-label="Queue scope" className="flex gap-2 flex-wrap">
        {SCOPES.map((s) => {
          const active = s.key === scope.key;
          return (
            <Link
              key={s.key}
              href={hrefWith(PATH, sp, { scope: s.key === "all" ? undefined : s.key, offset: undefined })}
              aria-current={active ? "page" : undefined}
              className={`px-3 py-1.5 rounded-lg text-xs font-semibold border ${
                active ? "bg-gray-900 text-on-action border-gray-900" : "bg-surface text-gray-600 border-gray-200 hover:bg-gray-50"
              }`}
            >
              {s.label}
            </Link>
          );
        })}
      </nav>

      <ReportFilters
        basePath={PATH}
        initial={values}
        fields={["q", "severity", "category", "target_type"]}
        fixed={scope.key === "all" ? {} : { scope: scope.key }}
      />

      {!page.ok ? (
        <ErrorState message={page.error} />
      ) : page.data.items.length === 0 ? (
        filtered || scope.key !== "all" ? (
          <EmptyState title="Nothing in this view" body="No open report matches this scope and these filters." action={{ href: PATH, label: "Show every open report" }} />
        ) : (
          <EmptyState title="The queue is clear" body="Every report has a decision. New reports appear here as they arrive." />
        )
      ) : (
        <>
          <p className="text-[13px] text-gray-500">
            {page.data.total} open report{page.data.total === 1 ? "" : "s"} · most serious first, then longest waiting
          </p>
          <ReportsTable items={page.data.items} showClosedOutcome={false} />
          <Pagination total={page.data.total} limit={page.data.limit} offset={page.data.offset} hrefFor={(offset) => hrefWith(PATH, sp, { offset })} />
        </>
      )}
    </div>
  );
}
