import Link from "next/link";
import type { LedgerEntry } from "@/lib/moderation-api";
import { fmtDateTime, humanise, RESTRICTION_KIND_LABELS } from "@/lib/moderation-labels";
import { ActionBadge } from "./Badges";

const BASE = "/dashboard/trust-safety";

const ROLE_SHORT: Record<string, string> = {
  support_agent: "Support",
  senior_admin: "Senior",
  super_admin: "Super",
};

/**
 * Ledger rows as they were written: who, in what role AT THE TIME, why, and
 * the state before and after. Nothing here can be edited — a correction is a
 * new row that says so.
 */
export default function Ledger({
  entries,
  showTarget = false,
  empty = "No actions recorded.",
}: {
  entries: LedgerEntry[];
  showTarget?: boolean;
  empty?: string;
}) {
  if (entries.length === 0) return <p className="text-[13px] text-gray-400">{empty}</p>;
  return (
    <ul className="divide-y divide-gray-100">
      {entries.map((e) => (
        <li key={e.id} className="py-3 first:pt-0 last:pb-0">
          <div className="flex flex-wrap items-center gap-2">
            <ActionBadge type={e.action_type} />
            {e.action_type === "restriction_lifted" && typeof e.metadata?.kind === "string" && (
              <span className="text-[11.5px] text-gray-500">{RESTRICTION_KIND_LABELS[e.metadata.kind] ?? e.metadata.kind}</span>
            )}
            {e.action_type !== "restriction_lifted" && typeof e.metadata?.ends_at === "string" && (
              <span className="text-[11.5px] text-gray-500">until {fmtDateTime(e.metadata.ends_at)}</span>
            )}
            <time dateTime={e.created_at} className="text-[11.5px] text-gray-400 tabular-nums">
              {fmtDateTime(e.created_at)}
            </time>
            <span className="font-mono text-[10.5px] text-gray-400" title="Quote this reference in an appeal or handover">
              {e.reference}
            </span>
          </div>
          <p className="text-[12px] text-gray-500 mt-1">
            {e.actor_type === "system" ? (
              "System"
            ) : (
              <>
                {e.admin_email ?? "Unknown admin"}
                {e.admin_role && <span className="text-gray-400"> · {ROLE_SHORT[e.admin_role] ?? e.admin_role}</span>}
              </>
            )}
            {showTarget && e.target_user && (
              <>
                {" → "}
                <Link href={`${BASE}/users/${encodeURIComponent(e.target_user_id)}`} className="font-medium text-info-700 hover:underline">
                  {e.target_user.name ?? e.target_user_id}
                </Link>
              </>
            )}
            {e.report_id && (
              <>
                {" · "}
                <Link href={`${BASE}/reports/${e.report_id}`} className="text-info-700 hover:underline">
                  report
                </Link>
              </>
            )}
            {e.content_type && <span className="text-gray-400"> · {e.content_type === "post" ? "listing" : "message"}</span>}
          </p>
          {e.action_type === "note_added" ? (
            <p className="text-[13px] text-gray-800 mt-1.5 whitespace-pre-line break-words">{e.internal_note ?? e.reason}</p>
          ) : (
            <p className="text-[13px] text-gray-800 mt-1.5 whitespace-pre-line break-words">{e.reason}</p>
          )}
          {e.action_type !== "note_added" && (e.internal_note || hasState(e)) && (
            <details className="mt-1.5 group">
              <summary className="text-[11.5px] font-semibold text-gray-500 cursor-pointer select-none hover:text-gray-700">
                {e.internal_note ? "Internal note and details" : "Details"}
              </summary>
              <div className="mt-2 space-y-2">
                {e.internal_note && (
                  <p className="text-[12.5px] text-gray-700 bg-accent-50 border border-accent-100 rounded-md px-2.5 py-2 whitespace-pre-line break-words">
                    <span className="block text-[10.5px] font-semibold uppercase tracking-wide text-accent-700 mb-0.5">Internal — admins only</span>
                    {e.internal_note}
                  </p>
                )}
                {hasState(e) && (
                  <div className="grid sm:grid-cols-2 gap-2">
                    <StateBlock title="Before" value={e.previous_state} />
                    <StateBlock title="After" value={e.new_state} />
                  </div>
                )}
                <p className="text-[10.5px] text-gray-400 font-mono">
                  #{e.chain_seq}
                  {e.request_id ? ` · request ${e.request_id}` : ""}
                </p>
              </div>
            </details>
          )}
        </li>
      ))}
    </ul>
  );
}

function hasState(e: LedgerEntry): boolean {
  const empty = (v: unknown) => !v || (typeof v === "object" && Object.keys(v as object).length === 0);
  return !empty(e.previous_state) || !empty(e.new_state);
}

function StateBlock({ title, value }: { title: string; value: Record<string, unknown> }) {
  return (
    <div className="rounded-md border border-gray-100 bg-gray-50 px-2.5 py-2 min-w-0">
      <p className="text-[10.5px] font-semibold uppercase tracking-wide text-gray-400 mb-1">{title}</p>
      {!value || Object.keys(value).length === 0 ? (
        <p className="text-[12px] text-gray-400">—</p>
      ) : (
        <dl className="space-y-0.5">
          {Object.entries(value).map(([k, v]) => (
            <div key={k} className="flex gap-2 text-[12px]">
              <dt className="text-gray-500 shrink-0">{humanise(k)}</dt>
              <dd className="text-gray-800 min-w-0 break-words">{render(v)}</dd>
            </div>
          ))}
        </dl>
      )}
    </div>
  );
}

function render(v: unknown): string {
  if (v === null || v === undefined) return "—";
  if (typeof v === "boolean") return v ? "yes" : "no";
  if (typeof v === "string") {
    if (/^\d{4}-\d{2}-\d{2}T/.test(v)) return fmtDateTime(v);
    return /^[a-z]+(_[a-z]+)*$/.test(v) ? humanise(v) : v; // enums read as words; ids stay as written
  }
  if (Array.isArray(v)) {
    if (v.length === 0) return "none";
    return v
      .map((x) => (x && typeof x === "object" && "kind" in x ? RESTRICTION_KIND_LABELS[String((x as { kind: unknown }).kind)] ?? String((x as { kind: unknown }).kind) : render(x)))
      .join(", ");
  }
  return JSON.stringify(v);
}
