import Link from "next/link";
import RestoringAccess from "@/app/dashboard/disputes/RestoringAccess";
import Ledger from "@/components/moderation/Ledger";
import { EmptyState, ErrorState, Pagination } from "@/components/moderation/States";
import { getCurrentAdmin } from "@/lib/api";
import { getAuditIntegrity, listAudit, listModerationAdmins, settle, type AuditIntegrity, type Settled } from "@/lib/moderation-api";
import { ACTION_LABELS, fmtDateTime, roleAtLeast } from "@/lib/moderation-labels";
import { dayBoundary, hrefWith, offsetOf, param, type SearchParams } from "@/lib/moderation-query";

export const dynamic = "force-dynamic";

const PATH = "/dashboard/trust-safety/audit";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PAGE = 50;

type PageProps = { searchParams: Promise<SearchParams> };

/**
 * The moderation ledger. Append-only in the database (no role, the owner
 * included, can edit or delete a row) and hash-chained per account, so an
 * edit made by going around the database's own rules is detectable.
 */
export default async function AuditPage({ searchParams }: PageProps) {
  const admin = await getCurrentAdmin();
  if (!admin) return <RestoringAccess />;

  const sp = await searchParams;
  const actionType = param(sp, "action_type");
  const adminId = param(sp, "admin_id");
  const userId = param(sp, "user_id");
  const ref = param(sp, "ref")?.replace(/[^0-9A-Fa-f]/g, "");
  const from = param(sp, "from");
  const to = param(sp, "to");

  const query = {
    action_type: actionType && actionType in ACTION_LABELS ? actionType : undefined,
    admin_id: adminId && UUID.test(adminId) ? adminId : undefined,
    user_id: userId && /^[A-Za-z0-9_-]{1,128}$/.test(userId) ? userId : undefined,
    ref: ref && ref.length >= 4 && ref.length <= 32 ? ref : undefined,
    from: dayBoundary(from, "start"),
    to: dayBoundary(to, "end"),
    limit: PAGE,
    offset: offsetOf(sp),
  };
  const senior = roleAtLeast(admin.role, "senior_admin");

  const [page, admins, integrity] = await Promise.all([
    settle(listAudit(query)),
    settle(listModerationAdmins()),
    senior ? settle(getAuditIntegrity()) : Promise.resolve(null),
  ]);
  const filtered = Object.entries(query).some(([k, v]) => !["limit", "offset"].includes(k) && v);

  return (
    <div className="space-y-5">
      {integrity && <IntegrityPanel result={integrity} />}

      <form action={PATH} className="card p-3 sm:p-4 grid grid-cols-2 md:grid-cols-3 xl:grid-cols-6 gap-2 items-end">
        <label className="block">
          <span className="text-[11px] font-semibold text-gray-500">Action</span>
          <select name="action_type" defaultValue={query.action_type ?? ""} className="input mt-1">
            <option value="">All actions</option>
            {Object.entries(ACTION_LABELS).map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <label className="block">
          <span className="text-[11px] font-semibold text-gray-500">Admin</span>
          <select name="admin_id" defaultValue={query.admin_id ?? ""} className="input mt-1">
            <option value="">Any admin</option>
            {admins.ok &&
              admins.data.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.name || a.email}
                </option>
              ))}
          </select>
        </label>
        <label className="block">
          <span className="text-[11px] font-semibold text-gray-500">Account id</span>
          <input name="user_id" defaultValue={query.user_id ?? ""} className="input mt-1 font-mono" placeholder="Firebase UID" maxLength={128} />
        </label>
        <label className="block">
          <span className="text-[11px] font-semibold text-gray-500">Reference</span>
          <input name="ref" defaultValue={query.ref ?? ""} className="input mt-1 font-mono uppercase" placeholder="e.g. 7F3A9C21" maxLength={32} />
        </label>
        <label className="block">
          <span className="text-[11px] font-semibold text-gray-500">From</span>
          <input type="date" name="from" defaultValue={from ?? ""} className="input mt-1" />
        </label>
        <label className="block">
          <span className="text-[11px] font-semibold text-gray-500">To</span>
          <input type="date" name="to" defaultValue={to ?? ""} className="input mt-1" />
        </label>
        <div className="col-span-2 md:col-span-3 xl:col-span-6 flex gap-2 justify-end">
          {filtered && (
            <Link href={PATH} className="btn-ghost border border-gray-200">
              Clear
            </Link>
          )}
          <button type="submit" className="btn-primary">
            Apply
          </button>
        </div>
      </form>

      {!page.ok ? (
        <ErrorState message={page.error} />
      ) : page.data.items.length === 0 ? (
        filtered ? (
          <EmptyState title="No actions match" body="Clear a filter or widen the dates." action={{ href: PATH, label: "Clear all filters" }} />
        ) : (
          <EmptyState title="No moderation actions yet" body="Every warning, restriction, lift, content change, report decision and note will be recorded here." />
        )
      ) : (
        <>
          <p className="text-[13px] text-gray-500">
            {page.data.total} action{page.data.total === 1 ? "" : "s"} · newest first · references are what users and admins quote
          </p>
          <div className="card p-4 sm:p-5">
            <Ledger entries={page.data.items} showTarget />
          </div>
          <Pagination total={page.data.total} limit={page.data.limit} offset={page.data.offset} hrefFor={(offset) => hrefWith(PATH, sp, { offset })} />
        </>
      )}
    </div>
  );
}

function IntegrityPanel({ result }: { result: Settled<AuditIntegrity> }) {
  if (!result.ok) {
    return (
      <div className="card p-4 border border-caution-200 bg-caution-50 text-[13px] text-caution-800">
        The integrity check could not run: {result.error}
      </div>
    );
  }
  const r = result.data;
  return (
    <div className={`card p-4 border ${r.intact ? "border-positive-200" : "border-critical-300 bg-critical-50"}`}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className={`text-[13.5px] font-semibold ${r.intact ? "text-positive-700" : "text-critical-700"}`}>
          {r.intact ? "Ledger intact" : "Ledger integrity problem"}
        </p>
        <p className="text-[11.5px] text-gray-400">Checked {fmtDateTime(r.checked_at)}</p>
      </div>
      <p className="text-[12.5px] text-gray-600 mt-1">
        {r.intact
          ? `All ${r.rows} rows re-hashed: no edited row, no broken link, no gap in any account's sequence.`
          : `${r.edited_rows} edited row(s), ${r.broken_links} broken link(s), ${r.sequence_gaps} sequence gap(s) across ${r.rows} rows. Someone changed the ledger outside the moderation functions — escalate to the database owner.`}
      </p>
    </div>
  );
}
