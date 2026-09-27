import Link from "next/link";
import RestoringAccess from "@/app/dashboard/disputes/RestoringAccess";
import ReportFilters from "@/components/moderation/ReportFilters";
import ReportsTable from "@/components/moderation/ReportsTable";
import SummaryStrip from "@/components/moderation/SummaryStrip";
import { EmptyState, ErrorState, Pagination } from "@/components/moderation/States";
import { getCurrentAdmin } from "@/lib/api";
import { getModerationSummary, listReports, settle } from "@/lib/moderation-api";
import { hrefWith, param, reportApiQuery, reportFilterValues, type SearchParams } from "@/lib/moderation-query";

// Reports are live operational data.
export const dynamic = "force-dynamic";

const PATH = "/dashboard/trust-safety/reports";

type PageProps = { searchParams: Promise<SearchParams> };

export default async function ReportsPage({ searchParams }: PageProps) {
  const admin = await getCurrentAdmin();
  if (!admin) return <RestoringAccess />;

  const sp = await searchParams;
  const query = reportApiQuery(sp);
  const [summary, page] = await Promise.all([settle(getModerationSummary()), settle(listReports(query))]);

  const values = reportFilterValues(sp);
  const filtered = Object.entries(values).some(([k, v]) => k !== "sort" && v) || !!query.reported_user_id || !!query.reporter_id;

  return (
    <div className="space-y-5">
      <SummaryStrip summary={summary} />

      <ReportFilters
        basePath={PATH}
        initial={values}
        fixed={Object.fromEntries(
          [
            ["reported_user_id", query.reported_user_id],
            ["reporter_id", query.reporter_id],
          ].filter(([, v]) => v) as Array<[string, string]>,
        )}
      />

      {(query.reported_user_id || query.reporter_id) && (
        <div className="flex flex-wrap items-center gap-2 text-[12.5px]">
          {query.reported_user_id && (
            <span className="badge bg-gray-100 text-gray-700">
              About account <span className="font-mono ml-1">{query.reported_user_id}</span>
            </span>
          )}
          {query.reporter_id && (
            <span className="badge bg-gray-100 text-gray-700">
              Filed by account <span className="font-mono ml-1">{query.reporter_id}</span>
            </span>
          )}
          <Link href={hrefWith(PATH, sp, { reported_user_id: undefined, reporter_id: undefined, offset: undefined })} className="text-info-700 font-semibold hover:underline">
            Show all accounts
          </Link>
        </div>
      )}

      {!page.ok ? (
        <ErrorState message={page.error} />
      ) : page.data.items.length === 0 ? (
        filtered ? (
          <EmptyState title="No reports match these filters" body="Widen the date range or clear a filter." action={{ href: PATH, label: "Clear all filters" }} />
        ) : (
          <EmptyState title="No reports yet" body="When someone reports an account, listing, application or message in the app, it appears here." />
        )
      ) : (
        <>
          <p className="text-[13px] text-gray-500">
            {page.data.total} report{page.data.total === 1 ? "" : "s"}
            {param(sp, "sort") === "queue" ? " · most serious first" : " · newest first"}
          </p>
          <ReportsTable items={page.data.items} />
          <Pagination
            total={page.data.total}
            limit={page.data.limit}
            offset={page.data.offset}
            hrefFor={(offset) => hrefWith(PATH, sp, { offset })}
          />
        </>
      )}
    </div>
  );
}
