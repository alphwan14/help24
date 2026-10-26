import Link from "next/link";
import { notFound } from "next/navigation";
import { PostStatusBadge } from "@/components/PostStatusBadge";
import { ACTIVITY_LABELS, ACTIVITY_MEANING, ACTIVITY_STYLES, activityState, agoLabel, lastActiveAt } from "@/lib/activity";
import { mailtoHref, telHref, whatsappHref } from "@/lib/contact-links";
import { normalizeStatus, STATUS_LABELS as DISPUTE_LABELS, STATUS_STYLES as DISPUTE_STYLES } from "@/lib/dispute-status";
import { loadMember, type MemberProfile, type Section } from "@/lib/member-profile";
import { ACCOUNT_STATUS_LABELS, ACCOUNT_STATUS_STYLES, fmtDate, fmtDateTime } from "@/lib/moderation-labels";
import { fmtKes } from "@/lib/post-display";
import { ratingLabel } from "@/lib/reputation";

// One person, now: their activity and money must not be a minute old.
export const dynamic = "force-dynamic";

const USER_ID = /^[A-Za-z0-9_-]{1,128}$/;

type PageProps = { params: Promise<{ id: string }> };

const TYPE_LABELS: Record<string, string> = { request: "Request", offer: "Offer", job: "Job" };

const MONEY_LABELS: Record<string, { label: string; cls: string }> = {
  pending: { label: "Waiting for M-Pesa", cls: "bg-caution-100 text-caution-700" },
  paid: { label: "Held in escrow", cls: "bg-info-100 text-info-700" },
  locked: { label: "Held in escrow", cls: "bg-info-100 text-info-700" },
  payout_pending: { label: "Paying out", cls: "bg-info-100 text-info-700" },
  released: { label: "Paid out", cls: "bg-positive-100 text-positive-700" },
  refunded: { label: "Refunded", cls: "bg-gray-100 text-gray-600" },
  disputed: { label: "Disputed", cls: "bg-critical-100 text-critical-700" },
  failed: { label: "Failed", cls: "bg-gray-100 text-gray-500" },
};

function MoneyBadge({ status }: { status: string }) {
  const s = MONEY_LABELS[status] ?? { label: status, cls: "bg-gray-100 text-gray-600" };
  return <span className={`badge whitespace-nowrap ${s.cls}`}>{s.label}</span>;
}

/** A request has a page of its own; offers and jobs do not yet. */
function postHref(p: { id: string; type?: string | null }): string | null {
  return p.type === "request" ? `/dashboard/marketplace/requests/${p.id}` : null;
}

function Title({ text, href }: { text: string | null; href: string | null }) {
  const t = text?.trim() || "Untitled listing";
  return href ? (
    <Link href={href} className="font-medium text-gray-900 hover:underline">
      {t}
    </Link>
  ) : (
    <span className="font-medium text-gray-900">{t}</span>
  );
}

function ListCard<T>({
  title,
  section,
  empty,
  children,
}: {
  title: string;
  section: Section<T>;
  empty: string;
  children: (rows: T[]) => React.ReactNode;
}) {
  return (
    <section className="card p-4 sm:p-5" aria-label={title}>
      <div className="flex items-baseline justify-between gap-3 mb-3">
        <h2 className="text-[14px] font-semibold text-gray-900">{title}</h2>
        {!section.failed && section.total != null && section.total > section.rows.length && (
          <span className="text-[11.5px] text-gray-400">
            latest {section.rows.length} of {section.total}
          </span>
        )}
      </div>
      {section.failed ? (
        <p className="text-[13px] text-gray-500">Could not be read just now — reload to try again.</p>
      ) : section.rows.length === 0 ? (
        <p className="text-[13px] text-gray-400">{empty}</p>
      ) : (
        <ul className="divide-y divide-gray-100 text-[13px]">{children(section.rows)}</ul>
      )}
    </section>
  );
}

function Row({ children }: { children: React.ReactNode }) {
  return <li className="flex items-center justify-between gap-3 py-2.5 first:pt-0 last:pb-0">{children}</li>;
}

function Stat({ label, value, hint }: { label: string; value: React.ReactNode; hint?: string }) {
  return (
    <div className="card px-4 py-3">
      <p className="text-[11.5px] font-medium text-gray-500">{label}</p>
      <p className="text-lg font-semibold text-gray-900 font-tabular mt-0.5">{value}</p>
      {hint && <p className="text-[11px] text-gray-400 mt-0.5">{hint}</p>}
    </div>
  );
}

function count(s: Section<unknown>): string {
  return s.failed || s.total == null ? "—" : String(s.total);
}

function ContactAction({ href, label, external }: { href: string | null; label: string; external?: boolean }) {
  if (!href) return null;
  return (
    <a
      href={href}
      {...(external ? { target: "_blank", rel: "noopener noreferrer" } : {})}
      className="btn-ghost border border-gray-200"
    >
      {label}
    </a>
  );
}

function Header({ m }: { m: MemberProfile }) {
  const u = m.user;
  const now = Date.now();
  const state = activityState(u, now);
  const last = lastActiveAt(u);
  const photo = u.profile_image || u.photo_url || u.avatar_url;
  const name = u.name?.trim() || "Unnamed member";
  const phone = u.phone_number?.trim() || u.phone?.trim() || null;

  return (
    <section className="card p-4 sm:p-5 space-y-4">
      <div className="flex items-start gap-4">
        {photo ? (
          // eslint-disable-next-line @next/next/no-img-element -- member photos are on Supabase/Google hosts
          <img src={photo} alt="" className="h-14 w-14 rounded-full object-cover bg-gray-100 shrink-0" />
        ) : (
          <div className="h-14 w-14 rounded-full bg-gray-100 text-gray-500 flex items-center justify-center text-lg font-semibold shrink-0">
            {name.charAt(0).toUpperCase()}
          </div>
        )}
        <div className="min-w-0 flex-1">
          <h2 className="text-lg font-bold text-gray-900 leading-tight">{name}</h2>
          {u.profession && <p className="text-[13px] text-gray-500 mt-0.5">{u.profession}</p>}
          <div className="flex flex-wrap gap-1.5 mt-2">
            <span className={`badge ${ACTIVITY_STYLES[state]}`} title={ACTIVITY_MEANING[state]}>
              {ACTIVITY_LABELS[state]}
            </span>
            {m.accountStatus && (
              <span className={`badge ${ACCOUNT_STATUS_STYLES[m.accountStatus] ?? "bg-gray-100 text-gray-600"}`}>
                {ACCOUNT_STATUS_LABELS[m.accountStatus] ?? m.accountStatus}
              </span>
            )}
            {u.role === "admin" && <span className="badge bg-indigo-100 text-indigo-700">Admin</span>}
            {u.is_verified && <span className="badge bg-positive-100 text-positive-700">Verified</span>}
          </div>
        </div>
      </div>

      <dl className="grid gap-x-6 gap-y-2 sm:grid-cols-2 text-[13px]">
        <div className="flex gap-2">
          <dt className="text-gray-500 w-28 shrink-0">Last used the app</dt>
          <dd className="text-gray-900">
            {state === "online" ? "Right now" : last ? `${agoLabel(last, now)} · ${fmtDateTime(new Date(last).toISOString())}` : "Never"}
          </dd>
        </div>
        <div className="flex gap-2">
          <dt className="text-gray-500 w-28 shrink-0">Joined</dt>
          <dd className="text-gray-900">{fmtDate(u.created_at)}</dd>
        </div>
        <div className="flex gap-2">
          <dt className="text-gray-500 w-28 shrink-0">Phone</dt>
          <dd className="text-gray-900 font-tabular">{phone ?? "—"}</dd>
        </div>
        <div className="flex gap-2 min-w-0">
          <dt className="text-gray-500 w-28 shrink-0">Email</dt>
          <dd className="text-gray-900 truncate">{u.email ?? "—"}</dd>
        </div>
        <div className="flex gap-2">
          <dt className="text-gray-500 w-28 shrink-0">Push messages</dt>
          <dd className="text-gray-900">
            {u.notifications_enabled === false
              ? "Turned off in the app"
              : m.pushDevices > 0
                ? `Reach ${m.pushDevices === 1 ? "1 phone" : `${m.pushDevices} phones`}`
                : "No phone registered"}
          </dd>
        </div>
        <div className="flex gap-2 min-w-0">
          <dt className="text-gray-500 w-28 shrink-0">Member ID</dt>
          <dd className="text-gray-500 font-mono text-[12px] truncate">{u.id}</dd>
        </div>
      </dl>

      {u.bio?.trim() && <p className="text-[13px] text-gray-600 leading-relaxed">{u.bio.trim()}</p>}

      <div className="flex flex-wrap gap-2">
        <ContactAction href={telHref(phone)} label="Call" />
        <ContactAction href={whatsappHref(phone)} label="WhatsApp" external />
        <ContactAction href={mailtoHref(u.email)} label="Email" />
        <Link href={`/dashboard/trust-safety/users/${encodeURIComponent(u.id)}`} className="btn-ghost border border-gray-200">
          Trust &amp; Safety record
          {m.openReports ? (
            <span className="ml-2 badge bg-critical-100 text-critical-700">{m.openReports} open</span>
          ) : null}
        </Link>
      </div>
    </section>
  );
}

export default async function MemberPage({ params }: PageProps) {
  const { id: raw } = await params;
  const id = decodeURIComponent(raw);
  if (!USER_ID.test(id)) notFound();

  let m: MemberProfile | null;
  try {
    m = await loadMember(id);
  } catch {
    return <p className="card p-4 text-sm text-gray-500">This member could not be read just now. Reload to try again.</p>;
  }
  if (!m) notFound();

  const rating = ratingLabel(m.rep ?? undefined);

  return (
    <div className="space-y-5">
      <Link href="/dashboard/users" className="text-[12.5px] font-semibold text-gray-500 hover:text-gray-800">
        ← All users
      </Link>

      <Header m={m} />

      <div className="grid gap-3 grid-cols-2 lg:grid-cols-5">
        <Stat label="Posted" value={count(m.posted)} hint="requests, offers, jobs" />
        <Stat label="Hired for" value={count(m.hired)} hint="chosen as the provider" />
        <Stat label="Applied" value={count(m.applications)} hint="offers and applications sent" />
        <Stat label="Payments made" value={count(m.payments)} hint="M-Pesa attempts, any outcome" />
        <Stat
          label="As a provider"
          value={rating ?? (m.rep ? "No reviews" : "—")}
          hint={m.rep ? `${m.rep.completed_jobs} jobs completed` : "no completed work yet"}
        />
      </div>

      <div className="grid gap-5 lg:grid-cols-2 items-start">
        <ListCard title="Posted" section={m.posted} empty="Has not posted anything.">
          {(rows) =>
            rows.map((p) => (
              <Row key={p.id}>
                <div className="min-w-0">
                  <Title text={p.title} href={postHref(p)} />
                  <p className="text-[11.5px] text-gray-400">
                    {TYPE_LABELS[p.type ?? ""] ?? p.type} · {fmtDate(p.created_at)}
                  </p>
                </div>
                <PostStatusBadge status={p.status} archivedAt={p.archived_at} />
              </Row>
            ))
          }
        </ListCard>

        <ListCard title="Hired for" section={m.hired} empty="Has not been chosen as a provider yet.">
          {(rows) =>
            rows.map((p) => (
              <Row key={p.id}>
                <div className="min-w-0">
                  <Title text={p.title} href={postHref(p)} />
                  <p className="text-[11.5px] text-gray-400">{fmtDate(p.created_at)}</p>
                </div>
                <PostStatusBadge status={p.status} archivedAt={p.archived_at} />
              </Row>
            ))
          }
        </ListCard>

        <ListCard title="Applied to" section={m.applications} empty="Has not applied to or offered on anything.">
          {(rows) =>
            rows.map((a) => (
              <Row key={a.id}>
                <div className="min-w-0">
                  <Title text={a.posts?.title ?? null} href={postHref({ id: a.post_id, type: a.posts?.type })} />
                  <p className="text-[11.5px] text-gray-400">
                    {fmtDate(a.created_at)}
                    {a.proposed_price ? ` · offered ${fmtKes(a.proposed_price)}` : ""}
                  </p>
                </div>
                <PostStatusBadge status={a.posts?.status} />
              </Row>
            ))
          }
        </ListCard>

        <ListCard title="Payments made" section={m.payments} empty="Has not paid for anything through Help24.">
          {(rows) =>
            rows.map((t) => (
              <Row key={t.id}>
                <div className="min-w-0">
                  <span className="font-medium text-gray-900">{t.posts?.title?.trim() || "Listing"}</span>
                  <p className="text-[11.5px] text-gray-400">
                    {fmtDateTime(t.created_at)} · {fmtKes(Number(t.total_paid ?? t.amount ?? 0))}
                  </p>
                </div>
                <MoneyBadge status={t.status} />
              </Row>
            ))
          }
        </ListCard>

        <ListCard title="Money for their work" section={m.earnings} empty="Nothing paid into escrow for them yet.">
          {(rows) =>
            rows.map((e) => (
              <Row key={e.id}>
                <div className="min-w-0">
                  <span className="font-medium text-gray-900 font-tabular">{fmtKes(Number(e.amount ?? 0))}</span>
                  <p className="text-[11.5px] text-gray-400">
                    {fmtDate(e.created_at)}
                    {e.released_at ? ` · paid out ${fmtDate(e.released_at)}` : ""}
                  </p>
                </div>
                <MoneyBadge status={e.released_at ? "released" : e.status} />
              </Row>
            ))
          }
        </ListCard>

        <ListCard title="Disputes" section={m.disputes} empty="No disputes.">
          {(rows) =>
            rows.map((d) => {
              const s = normalizeStatus(d.status);
              return (
                <Row key={d.id}>
                  <div className="min-w-0">
                    <Link href={`/dashboard/disputes/${d.id}`} className="font-medium text-gray-900 hover:underline">
                      {d.reason?.trim() || "Dispute"}
                    </Link>
                    <p className="text-[11.5px] text-gray-400">
                      {fmtDate(d.created_at)} · {d.raised_by_user_id === m.user.id ? "raised by them" : "raised by the other side"}
                    </p>
                  </div>
                  <span className={`badge whitespace-nowrap ${DISPUTE_STYLES[s]}`}>{DISPUTE_LABELS[s]}</span>
                </Row>
              );
            })
          }
        </ListCard>
      </div>
    </div>
  );
}
