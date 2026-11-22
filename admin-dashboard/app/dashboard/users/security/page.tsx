import Link from "next/link";
import RestoringAccess from "@/app/dashboard/disputes/RestoringAccess";
import { ErrorState } from "@/components/moderation/States";
import { getCurrentAdmin } from "@/lib/api";
import { loadSecurityFeed, type FeedItem, type FeedPage } from "@/lib/security-feed";
import { CATEGORY_FILTERS, WHO_FILTERS, categoryFilter, personFilter, whoFilter } from "@/lib/security-format";

export const dynamic = "force-dynamic";

const PATH = "/dashboard/users/security";
const PAGE = 60;
const TZ = "Africa/Nairobi";

type SP = Record<string, string | string[] | undefined>;
const one = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v);

const ROLE_LABELS: Record<string, string> = {
  super_admin: "Super admin",
  senior_admin: "Senior admin",
  support_agent: "Support agent",
};

/**
 * Security log: who signed in, from where and on what, who was refused, and
 * what admins changed. Super admins only. Built from every ledger Help24 keeps
 * (lib/security-feed.ts); the sign-in parts need migration 146.
 */
export default async function SecurityLogPage({ searchParams }: { searchParams: Promise<SP> }) {
  const sp = await searchParams;
  const who = whoFilter(one(sp.who));
  const category = categoryFilter(one(sp.category));
  const person = personFilter(one(sp.person));
  const beforeRaw = one(sp.before);
  const before = beforeRaw && !Number.isNaN(Date.parse(beforeRaw)) ? new Date(beforeRaw).toISOString() : null;

  const admin = await getCurrentAdmin();
  if (!admin) return <RestoringAccess />;
  if (admin.role !== "super_admin") {
    return (
      <div className="card p-6 max-w-md">
        <h2 className="text-base font-bold text-gray-900">Restricted</h2>
        <p className="text-sm text-gray-500 mt-1">
          The security log is for super admins. You are signed in as <span className="font-semibold">{admin.email}</span>.
        </p>
      </div>
    );
  }

  let page: FeedPage | null = null;
  let failure: string | null = null;
  try {
    page = await loadSecurityFeed({ who, category, person, before, limit: PAGE });
  } catch (e) {
    failure = e instanceof Error ? e.message : "The log could not be read.";
  }

  const href = (over: Record<string, string | null>) => {
    const p = new URLSearchParams();
    const merged: Record<string, string | null> = {
      who: who === "all" ? null : who,
      category: category === "all" ? null : category,
      person: person ? `${person.kind}:${person.id}` : null,
      ...over,
    };
    for (const [k, v] of Object.entries(merged)) if (v) p.set(k, v);
    const s = p.toString();
    return s ? `${PATH}?${s}` : PATH;
  };

  const personName = person && page ? personLabel(page.items, `${person.kind}:${person.id}`) : null;

  return (
    <div className="space-y-5">
      <p className="text-[13px] text-gray-500">Sign-ins, refused access and admin changes, newest first. Times are Nairobi time.</p>

      <div className="flex flex-wrap items-center gap-2">
        <nav className="inline-flex rounded-lg border border-gray-200 bg-white p-0.5" aria-label="Whose activity">
          {WHO_FILTERS.map((f) => (
            <Link
              key={f.id}
              href={href({ who: f.id === "all" ? null : f.id, before: null })}
              aria-current={who === f.id ? "page" : undefined}
              className={[
                "px-3 py-1.5 rounded-md text-[13px] font-medium",
                who === f.id ? "bg-gray-900 text-white" : "text-gray-600 hover:text-gray-900",
              ].join(" ")}
            >
              {f.label}
            </Link>
          ))}
        </nav>
        <nav className="flex flex-wrap gap-1.5" aria-label="Kind of activity">
          {CATEGORY_FILTERS.map((f) => (
            <Link
              key={f.id}
              href={href({ category: f.id === "all" ? null : f.id, before: null })}
              aria-current={category === f.id ? "page" : undefined}
              className={[
                "px-2.5 py-1 rounded-full text-[12.5px] border",
                category === f.id ? "border-gray-900 text-gray-900 font-semibold" : "border-gray-200 text-gray-500 hover:text-gray-800",
              ].join(" ")}
            >
              {f.label}
            </Link>
          ))}
        </nav>
      </div>

      {person && (
        <div className="flex items-center gap-2 text-[13px]">
          <span className="text-gray-500">Only</span>
          <span className="inline-flex items-center gap-2 rounded-full bg-gray-100 px-3 py-1 font-medium text-gray-800">
            {personName ?? (person.kind === "admin" ? "this admin" : "this member")}
            <Link href={href({ person: null, before: null })} className="text-gray-400 hover:text-gray-700" aria-label="Show everyone">
              ×
            </Link>
          </span>
        </div>
      )}

      {page && !page.logReady && (
        <div className="card p-4 border border-caution-200 bg-caution-50 text-[13px] text-caution-800">
          Sign-ins, refused access and failed attempts start recording once database migration 146 is applied. Admin actions below are
          already recorded.
        </div>
      )}
      {page && page.missing.length > 0 && page.logReady && (
        <p className="text-[12.5px] text-gray-500">Not shown because they could not be read: {page.missing.join(", ")}.</p>
      )}

      {failure ? (
        <ErrorState message={failure} />
      ) : page && page.items.length === 0 ? (
        <div className="card px-6 py-12 text-center">
          <p className="text-sm font-semibold text-gray-800">Nothing here yet</p>
          <p className="text-[13px] text-gray-500 mt-1">
            {before ? "There is nothing older than this." : "Try Everyone and All activity, or come back after the next sign-in."}
          </p>
        </div>
      ) : page ? (
        <>
          <div className="card divide-y divide-gray-100">
            {groupByDay(page.items).map(({ day, items }) => (
              <section key={day}>
                <h2 className="px-4 sm:px-5 pt-4 pb-2 text-[11.5px] font-semibold uppercase tracking-wide text-gray-400">{day}</h2>
                <ul>
                  {items.map((item) => (
                    <Row key={item.id} item={item} personHref={item.actor.person ? href({ person: item.actor.person, before: null }) : null} />
                  ))}
                </ul>
              </section>
            ))}
          </div>
          {page.nextBefore && (
            <div className="flex justify-center">
              <Link href={href({ before: page.nextBefore })} className="btn-ghost border border-gray-200">
                Show older
              </Link>
            </div>
          )}
        </>
      ) : null}
    </div>
  );
}

function Row({ item, personHref }: { item: FeedItem; personHref: string | null }) {
  const failed = item.outcome === "failure";
  const name = item.actor.name || item.actor.email || "Unknown";
  const inlineReason = failed && item.reason ? item.reason : null;
  const facts = [
    inlineReason,
    item.actor.role ? ROLE_LABELS[item.actor.role] ?? item.actor.role : item.who === "member" ? "Member" : null,
    item.place,
    item.device,
    item.ip,
  ].filter(Boolean) as string[];
  const detailReason = inlineReason ? null : item.reason;
  const hasDetails = Boolean(detailReason || item.userAgent || (item.actor.email && item.actor.name));

  return (
    <li className="px-4 sm:px-5 py-3 hover:bg-gray-50/60">
      <div className="flex items-start gap-3">
        <span
          aria-hidden
          className={["mt-1.5 h-2 w-2 shrink-0 rounded-full", failed ? "bg-critical-500" : item.category === "admin_action" ? "bg-info-500" : "bg-gray-300"].join(" ")}
        />
        <div className="min-w-0 flex-1">
          <p className="text-[13.5px] text-gray-900 leading-snug">
            {personHref ? (
              <Link href={personHref} className="font-semibold hover:underline" title="Show only this person">
                {name}
              </Link>
            ) : (
              <span className="font-semibold">{name}</span>
            )}{" "}
            <span className={failed ? "text-critical-700" : "text-gray-700"}>
              {lower(item.action)}
              {item.method ? ` ${item.method}` : ""}
            </span>
            {item.target && (
              <>
                {": "}
                {item.target.href ? (
                  <Link href={item.target.href} className="text-gray-900 hover:underline">
                    {item.target.label}
                  </Link>
                ) : (
                  <span>{item.target.label}</span>
                )}
              </>
            )}
          </p>
          {facts.length > 0 && (
            <p className="mt-0.5 flex flex-wrap gap-x-3 gap-y-0.5 text-[12px] text-gray-500">
              {facts.map((f, i) => (
                <span
                  key={i}
                  className={f === inlineReason ? "font-medium text-critical-700" : f === item.ip ? "font-mono text-[11.5px]" : undefined}
                >
                  {f}
                </span>
              ))}
            </p>
          )}
          {hasDetails && (
            <details className="mt-1 group">
              <summary className="cursor-pointer list-none text-[12px] font-medium text-gray-400 hover:text-gray-700">Details</summary>
              <dl className="mt-1.5 grid grid-cols-[auto,1fr] gap-x-3 gap-y-1 text-[12px]">
                {detailReason && (
                  <>
                    <dt className="text-gray-400">Reason</dt>
                    <dd className="text-gray-700">{detailReason}</dd>
                  </>
                )}
                {item.actor.email && item.actor.name && (
                  <>
                    <dt className="text-gray-400">Account</dt>
                    <dd className="text-gray-700 break-all">{item.actor.email}</dd>
                  </>
                )}
                {item.userAgent && (
                  <>
                    <dt className="text-gray-400">Browser</dt>
                    <dd className="text-gray-700 break-all font-mono text-[11px]">{item.userAgent}</dd>
                  </>
                )}
                <dt className="text-gray-400">Recorded by</dt>
                <dd className="text-gray-700">{item.source}</dd>
              </dl>
            </details>
          )}
        </div>
        <time dateTime={item.at} className="shrink-0 text-[12px] tabular-nums text-gray-400" title={fullTime(item.at)}>
          {clock(item.at)}
        </time>
      </div>
    </li>
  );
}

function lower(s: string): string {
  return s ? s[0].toLowerCase() + s.slice(1) : s;
}

function personLabel(items: FeedItem[], person: string): string | null {
  const hit = items.find((i) => i.actor.person === person);
  return hit ? hit.actor.name || hit.actor.email : null;
}

const dayKey = (iso: string) => new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(iso));

function groupByDay(items: FeedItem[]): Array<{ day: string; items: FeedItem[] }> {
  const today = dayKey(new Date().toISOString());
  const yesterday = dayKey(new Date(Date.now() - 86_400_000).toISOString());
  const out: Array<{ key: string; day: string; items: FeedItem[] }> = [];
  for (const item of items) {
    const key = dayKey(item.at);
    let group = out[out.length - 1];
    if (!group || group.key !== key) {
      const label =
        key === today
          ? "Today"
          : key === yesterday
            ? "Yesterday"
            : new Intl.DateTimeFormat("en-GB", { timeZone: TZ, weekday: "short", day: "numeric", month: "short", year: "numeric" }).format(new Date(item.at));
      group = { key, day: label, items: [] };
      out.push(group);
    }
    group.items.push(item);
  }
  return out.map(({ day, items }) => ({ day, items }));
}

function clock(iso: string): string {
  return new Intl.DateTimeFormat("en-GB", { timeZone: TZ, hour: "2-digit", minute: "2-digit" }).format(new Date(iso));
}

function fullTime(iso: string): string {
  return new Intl.DateTimeFormat("en-GB", { timeZone: TZ, dateStyle: "medium", timeStyle: "medium" }).format(new Date(iso)) + " (Nairobi)";
}
