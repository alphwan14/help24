import Link from "next/link";
import type { Person } from "@/lib/marketplace-people";
import { fmtPhone, telHref, type Candidate, type MatchTier } from "@/lib/provider-matching";
import { ACCOUNT_STATUS_LABELS, ACCOUNT_STATUS_STYLES, age } from "@/lib/moderation-labels";
import { ratingLabel, type ProviderRep } from "@/lib/reputation";

// The dashboard cannot message users outside a dispute. What it can do is put
// the right phone number in front of the admin — these are the pieces that do.

export function accountHref(userId: string): string {
  return `/dashboard/trust-safety/users/${encodeURIComponent(userId)}`;
}

/** A tap-to-call number, or a plain statement that there is none. */
export function PhoneLink({ phone, compact = false }: { phone: string | null | undefined; compact?: boolean }) {
  if (!phone) return <span className="text-[12px] text-gray-400">No phone on file</span>;
  const href = telHref(phone);
  const text = fmtPhone(phone);
  if (!href) return <span className="text-[12.5px] text-gray-700">{text}</span>;
  return (
    <a href={href} className={`font-semibold text-info-700 hover:underline whitespace-nowrap ${compact ? "text-[12.5px]" : "text-[13.5px]"}`}>
      {compact ? text : `Call ${text}`}
    </a>
  );
}

/** Name + number, for table cells. */
export function PersonCell({ person, fallback }: { person: Person | undefined; fallback: string | null }) {
  return (
    <div className="min-w-0">
      <p className="text-gray-700 truncate">{person?.name || person?.email || fallback || "—"}</p>
      <PhoneLink phone={person?.phone} compact />
    </div>
  );
}

/** Only what needs attention: an account that is not active, and open reports. */
export function StandingBadges({ person }: { person: Person }) {
  return (
    <>
      {person.accountStatus !== "active" && (
        <span className={`badge ${ACCOUNT_STATUS_STYLES[person.accountStatus] ?? "bg-gray-100 text-gray-600"}`}>
          {ACCOUNT_STATUS_LABELS[person.accountStatus] ?? person.accountStatus}
        </span>
      )}
      {person.openReports > 0 && (
        <Link
          href={`/dashboard/trust-safety/reports?reported_user_id=${encodeURIComponent(person.id)}`}
          className="badge bg-caution-100 text-caution-700 hover:underline"
        >
          {person.openReports} open report{person.openReports === 1 ? "" : "s"}
        </Link>
      )}
    </>
  );
}

/** Counts, never a percentage from a handful of jobs. */
export function TrackRecord({ rep }: { rep: ProviderRep | null }) {
  if (!rep || (rep.completed_jobs <= 0 && rep.total_reviews <= 0)) {
    return <p className="text-[12px] text-gray-400">No completed jobs on Help24 yet</p>;
  }
  const parts = [`${rep.completed_jobs} job${rep.completed_jobs === 1 ? "" : "s"} done`];
  const rating = ratingLabel(rep);
  if (rating) parts.push(`${rating} (${rep.total_reviews} review${rep.total_reviews === 1 ? "" : "s"})`);
  return (
    <p className="text-[12px] text-gray-500">
      {parts.join(" · ")}
      {rep.open_disputes > 0 && (
        <span className="text-caution-700 font-medium"> · {rep.open_disputes} open dispute{rep.open_disputes === 1 ? "" : "s"}</span>
      )}
    </p>
  );
}

/** One person on a request page: who they are, how to reach them, and whether anything is wrong. */
export function PersonCard({
  label,
  userId,
  person,
  showRecord = false,
}: {
  label: string;
  userId: string | null;
  person: Person | undefined;
  showRecord?: boolean;
}) {
  return (
    <section className="card p-4 space-y-2">
      <p className="text-[10.5px] font-semibold uppercase tracking-wide text-gray-400">{label}</p>
      {!userId ? (
        <p className="text-[13px] text-gray-400">No account on this listing.</p>
      ) : !person ? (
        <p className="text-[13px] text-gray-500">
          Account not found <span className="font-mono text-[11px] text-gray-400">({userId.slice(0, 12)}…)</span>
        </p>
      ) : (
        <>
          <div className="flex flex-wrap items-center gap-1.5">
            <Link href={accountHref(userId)} className="text-[14px] font-semibold text-gray-900 hover:underline">
              {person.name || person.email || "Unnamed account"}
            </Link>
            <StandingBadges person={person} />
          </div>
          <div>
            <PhoneLink phone={person.phone} />
          </div>
          {person.email && (
            <a href={`mailto:${person.email}`} className="block text-[12.5px] text-gray-500 hover:underline break-all">
              {person.email}
            </a>
          )}
          <p className="text-[11.5px] text-gray-400">
            {person.lastActive ? `Last active ${age(person.lastActive)} ago` : "Never signed in on record"}
          </p>
          {showRecord && <TrackRecord rep={person.rep} />}
        </>
      )}
    </section>
  );
}

export const TIER_LABELS: Record<MatchTier, string> = {
  same: "Same work",
  related: "Related trade",
  mentions: "Mentions it",
};

const TIER_STYLES: Record<MatchTier, string> = {
  same: "bg-positive-100 text-positive-700",
  related: "bg-info-100 text-info-700",
  mentions: "bg-gray-100 text-gray-600",
};

const TIER_HINTS: Record<MatchTier, string> = {
  same: "Their trade or open offer is in this request's category.",
  related: "An adjacent trade in the same group — worth a call, not a sure thing.",
  mentions: "Only a word of their trade appears in the request. Check before calling.",
};

export function TierChip({ tier }: { tier: MatchTier }) {
  return (
    <span className={`badge ${TIER_STYLES[tier]}`} title={TIER_HINTS[tier]}>
      {TIER_LABELS[tier]}
    </span>
  );
}

function distanceText(km: number | null): string {
  if (km == null) return "distance unknown";
  if (km < 1) return "under 1 km away";
  return `${Math.round(km)} km away`;
}

/** One person who could take the request, with the evidence and the number to call. */
export function CandidateRow({
  candidate,
  person,
  applied,
}: {
  candidate: Candidate;
  person: Person | undefined;
  applied: boolean;
}) {
  const [first, ...more] = candidate.offers;
  return (
    <li className="py-3 flex flex-wrap items-start justify-between gap-x-4 gap-y-2">
      <div className="min-w-0 space-y-1">
        <div className="flex flex-wrap items-center gap-1.5">
          <Link href={accountHref(candidate.userId)} className="text-[13.5px] font-semibold text-gray-900 hover:underline">
            {person?.name || person?.email || `Account ${candidate.userId.slice(0, 10)}…`}
          </Link>
          <TierChip tier={candidate.tier} />
          {applied && <span className="badge bg-positive-100 text-positive-700">Already applied</span>}
          {person && <StandingBadges person={person} />}
        </div>
        {first && (
          <p className="text-[12.5px] text-gray-600">
            Offers <span className="font-medium text-gray-800">{first.offer.category || "a service"}</span>
            {first.offer.title ? <> — “{first.offer.title}”</> : null}
            <span className="text-gray-400">
              {" · "}
              {first.offer.location || "no location"} · {distanceText(first.distanceKm)}
            </span>
          </p>
        )}
        {more.length > 0 && (
          <p className="text-[11.5px] text-gray-400">
            and {more.length} more matching offer{more.length === 1 ? "" : "s"}
          </p>
        )}
        {candidate.profile && (
          <p className="text-[12.5px] text-gray-600">
            Trade on their profile: <span className="font-medium text-gray-800">{candidate.profile.trade}</span>
          </p>
        )}
        <TrackRecord rep={person?.rep ?? null} />
      </div>
      <div className="text-right space-y-0.5 shrink-0">
        <PhoneLink phone={person?.phone} />
        {!person?.phone && person?.email && (
          <a href={`mailto:${person.email}`} className="block text-[12px] text-gray-500 hover:underline break-all">
            {person.email}
          </a>
        )}
        {person?.lastActive && <p className="text-[11.5px] text-gray-400">Last active {age(person.lastActive)} ago</p>}
      </div>
    </li>
  );
}
