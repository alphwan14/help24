import type { AccountSummary, Signals } from "@/lib/moderation-api";
import { age, fmtDate, fmtDateTime, RESTRICTION_KIND_LABELS } from "@/lib/moderation-labels";
import { AccountStatusBadge, Avatar, LayerTag } from "./Badges";

const PROVIDER_LABELS: Record<string, string> = {
  phone: "Phone",
  "google.com": "Google",
  password: "Email & password",
  "apple.com": "Apple",
};

/** Who the account is and how it signs in — platform records only. */
export function AccountHeader({ summary, compact = false }: { summary: AccountSummary; compact?: boolean }) {
  const u = summary.user;
  if (!u) return <p className="text-[13px] text-gray-400">This account no longer exists.</p>;
  const signIn = summary.sign_in;
  return (
    <div className="space-y-3">
      <div className="flex items-start gap-3">
        <Avatar name={u.name} src={u.avatar} size={compact ? 40 : 52} />
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <p className={`${compact ? "text-[14px]" : "text-[17px]"} font-semibold text-gray-900 truncate`}>{u.name?.trim() || "Unnamed account"}</p>
            <AccountStatusBadge status={summary.account.status} />
            {u.is_verified && <span className="badge bg-info-100 text-info-700">Verified</span>}
            {u.role === "admin" && <span className="badge bg-gray-900 text-on-action">Admin account</span>}
          </div>
          <p className="text-[12px] text-gray-500 mt-0.5">
            {[u.profession, `Member ${age(u.created_at)} · since ${fmtDate(u.created_at)}`].filter(Boolean).join(" · ")}
          </p>
          <p className="text-[11px] text-gray-400 font-mono mt-0.5 break-all">{u.id}</p>
        </div>
      </div>

      <dl className="grid grid-cols-2 gap-x-3 gap-y-1.5 text-[12px]">
        <Fact label="Signs in with">
          {signIn ? (signIn.providers.length ? signIn.providers.map((p) => PROVIDER_LABELS[p] ?? p).join(", ") : "—") : "Unavailable"}
        </Fact>
        <Fact label="Last sign-in">{signIn?.last_sign_in ? fmtDateTime(signIn.last_sign_in) : u.last_login ? fmtDateTime(u.last_login) : "—"}</Fact>
        <Fact label="Phone">
          {u.phone_number ?? "—"}
          {signIn?.phone_verified && <span className="text-positive-700"> · verified by OTP</span>}
        </Fact>
        <Fact label="Email">
          <span className="break-all">{u.email ?? "—"}</span>
          {u.email && signIn && <span className={signIn.email_verified ? "text-positive-700" : "text-gray-400"}>{signIn.email_verified ? " · verified" : " · unverified"}</span>}
        </Fact>
        {signIn?.disabled && (
          <Fact label="Firebase">
            <span className="text-critical-700 font-semibold">Sign-in disabled in Firebase</span>
          </Fact>
        )}
      </dl>
      {!compact && u.bio && <p className="text-[12.5px] text-gray-600 whitespace-pre-line border-l-2 border-gray-100 pl-3">{u.bio}</p>}
    </div>
  );
}

function Fact({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="min-w-0">
      <dt className="text-[10.5px] font-semibold uppercase tracking-wide text-gray-400">{label}</dt>
      <dd className="text-gray-700 mt-0.5">{children}</dd>
    </div>
  );
}

/** What is in force right now. */
export function ActiveRestrictions({ summary }: { summary: AccountSummary }) {
  const list = summary.account.active_restrictions;
  if (list.length === 0) return null;
  return (
    <ul className="space-y-2">
      {list.map((r) => (
        <li
          key={r.id}
          className={`rounded-lg border px-3 py-2 text-[12.5px] ${r.kind === "ban" ? "border-critical-200 bg-critical-50" : "border-caution-200 bg-caution-50"}`}
        >
          <p className="font-semibold text-gray-900">
            {RESTRICTION_KIND_LABELS[r.kind] ?? r.kind}
            <span className="font-normal text-gray-500"> · {r.ends_at ? `until ${fmtDateTime(r.ends_at)}` : "no end date"}</span>
          </p>
          <p className="text-gray-700 mt-0.5 whitespace-pre-line">{r.reason}</p>
          <p className="text-[10.5px] text-gray-400 font-mono mt-1">Ref {r.reference}</p>
        </li>
      ))}
    </ul>
  );
}

/**
 * DETERMINISTIC SIGNALS — counts an admin weighs, never a verdict. Nothing is
 * scored or combined: a number that looks like a probability invites being
 * treated as one. A figure is tinted only when it is a plain fact worth a
 * second look (money failed, a dispute lost, several different reporters).
 */
export function SignalsGrid({ s }: { s: Signals }) {
  const rating = s.avg_rating != null ? `${Number(s.avg_rating).toFixed(1)}★ (${s.total_reviews})` : s.total_reviews ? `${s.total_reviews} reviews` : "No reviews";
  const groups: Array<{ title: string; rows: Array<[string, React.ReactNode, boolean?]> }> = [
    {
      title: "Marketplace",
      rows: [
        ["Requests posted", s.requests_created],
        ["Offers posted", s.offers_created],
        ["Jobs posted", s.jobs_created],
        ["Applications made", s.applications_made],
        ["Jobs completed", s.completed_jobs],
        ["Rating", rating],
        // 0..1 (migration 055), and 0 when no job has concluded yet — which is "no record", not 0%.
        ["Completion rate", s.completion_rate != null && (s.completion_rate > 0 || s.completed_jobs > 0) ? `${Math.round(Number(s.completion_rate) * 100)}%` : "—"],
        ["Cancelled as provider", s.cancelled_as_provider, s.cancelled_as_provider > 0],
      ],
    },
    {
      title: "Money & disputes",
      rows: [
        ["Failed payments", s.failed_payments, s.failed_payments > 0],
        ["Disputes raised", s.disputes_raised],
        ["Disputes against them", s.disputes_against, s.disputes_against > 0],
      ],
    },
    {
      title: "Reports",
      rows: [
        ["Reports about them", s.reports_received],
        ["Still open", s.reports_received_open, s.reports_received_open > 0],
        ["Different people, all time", s.reports_received_distinct_reporters, s.reports_received_distinct_reporters >= 3],
        ["Different people, 30 days", s.reports_received_distinct_reporters_30d, s.reports_received_distinct_reporters_30d >= 2],
        ["Upheld with action", s.reports_received_actioned, s.reports_received_actioned > 0],
        ["Dismissed", s.reports_received_dismissed],
        ["Reports they filed", s.reports_made],
        ["…of which dismissed", s.reports_made_dismissed],
      ],
    },
    {
      title: "Moderation history",
      rows: [
        ["Warnings", s.warnings, s.warnings > 0],
        ["Suspensions", s.suspensions, s.suspensions > 0],
        ["Bans", s.bans, s.bans > 0],
        ["Partial restrictions", s.partial_restrictions, s.partial_restrictions > 0],
        ["Content hidden", s.content_removals, s.content_removals > 0],
      ],
    },
  ];
  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2">
        <LayerTag layer="platform" />
        <span className="text-[11.5px] text-gray-400">Counts from platform records — context, not a score</span>
      </div>
      <div className="grid sm:grid-cols-2 gap-3">
        {groups.map((g) => (
          <div key={g.title} className="rounded-lg border border-gray-100 p-3">
            <p className="text-[11px] font-semibold uppercase tracking-wide text-gray-400 mb-1.5">{g.title}</p>
            <dl className="space-y-1">
              {g.rows.map(([label, value, flag]) => (
                <div key={label} className="flex items-baseline justify-between gap-3 text-[12.5px]">
                  <dt className="text-gray-500">{label}</dt>
                  <dd className={`tabular-nums ${flag ? "font-semibold text-caution-700" : "text-gray-800"}`}>{value}</dd>
                </div>
              ))}
            </dl>
          </div>
        ))}
      </div>
    </div>
  );
}
