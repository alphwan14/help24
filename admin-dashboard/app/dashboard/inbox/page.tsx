import Link from "next/link";
import { FilterLink, FilterResults, FilterScope } from "@/components/FilterTransition";
import RestoringAccess from "../disputes/RestoringAccess";
import { ApiError, getCurrentAdmin, startEarly } from "@/lib/api";
import { agoLabel } from "@/lib/activity";
import {
  STATUS_LABELS,
  getSupportList,
  type ConversationStatus,
  type InboxLabel,
  type SupportList,
} from "@/lib/support";

// Members are waiting on these: never a cached render.
export const dynamic = "force-dynamic";

const STATUSES: ConversationStatus[] = ["open", "waiting", "closed"];
const CHIP = "badge bg-gray-100 text-gray-600";
const CHIP_ON = "badge bg-gray-900 text-on-action";

type PageProps = { searchParams: Promise<{ status?: string; label?: string }> };

/**
 * The Inbox: one row per conversation, newest activity first. Opens on All,
 * like a mailbox: an answered conversation stays in sight (marked "Waiting on
 * member") instead of seeming to vanish. Nothing here is ever deleted; the
 * status chips only narrow the view.
 */
export default async function InboxPage({ searchParams }: PageProps) {
  const params = await searchParams;
  const status: ConversationStatus | "all" = STATUSES.includes(params.status as ConversationStatus)
    ? (params.status as ConversationStatus)
    : "all";
  const label: InboxLabel | null =
    params.label === "support" || params.label === "general" || params.label === "security" ? params.label : null;

  const listRequest = startEarly(getSupportList({ status: status === "all" ? undefined : status, label: label ?? undefined }));
  const admin = await getCurrentAdmin();
  if (!admin) return <RestoringAccess />;

  let list: SupportList | null = null;
  let failure: string | null = null;
  try {
    list = await listRequest;
  } catch (e) {
    failure = e instanceof ApiError ? e.message : "The Inbox could not be read.";
  }

  const href = (s: ConversationStatus | "all", l: InboxLabel | null) => {
    const q = new URLSearchParams();
    if (s !== "all") q.set("status", s);
    if (l) q.set("label", l);
    const qs = q.toString();
    return `/dashboard/inbox${qs ? `?${qs}` : ""}`;
  };
  const now = Date.now();
  const securityOpen = list?.open_by_label?.security ?? 0;

  return (
    <FilterScope>
      <div className="space-y-5">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex flex-wrap items-center gap-2" data-testid="inbox-status-filters">
            <FilterLink href={href("all", label)} active={status === "all"} className={CHIP} activeClassName={CHIP_ON}>
              All
            </FilterLink>
            {STATUSES.map((s) => (
              <FilterLink key={s} href={href(s, label)} active={status === s} className={CHIP} activeClassName={CHIP_ON}>
                {STATUS_LABELS[s]}
                {list ? <span className="ml-1.5 opacity-70">{list.counts[s]}</span> : null}
              </FilterLink>
            ))}
          </div>
          <div className="flex items-center gap-2 text-[13px]">
            <FilterLink href={href(status, null)} active={!label} className="text-gray-500 hover:text-gray-900" activeClassName="font-semibold text-gray-900">
              Every inbox
            </FilterLink>
            <FilterLink href={href(status, "support")} active={label === "support"} className="text-gray-500 hover:text-gray-900" activeClassName="font-semibold text-gray-900">
              Support
            </FilterLink>
            <FilterLink href={href(status, "general")} active={label === "general"} className="text-gray-500 hover:text-gray-900" activeClassName="font-semibold text-gray-900">
              General
            </FilterLink>
            {/* Kept apart: security@ mail is never in "Every inbox". */}
            <FilterLink
              href={href(status, "security")}
              active={label === "security"}
              className="ml-3 text-gray-500 hover:text-gray-900"
              activeClassName="ml-3 font-semibold text-gray-900"
            >
              Security
              {securityOpen > 0 && <span className="ml-1.5 text-caution-700" data-testid="security-open">{securityOpen}</span>}
            </FilterLink>
          </div>
        </div>

        {label === "security" && (
          <p className="text-[13px]">
            <Link href="/dashboard/inbox/new?from=security" className="font-medium text-gray-900 hover:underline" data-testid="security-new">
              New message from security@
            </Link>
          </p>
        )}

        <FilterResults>
          {failure ? (
            <p role="alert" className="rounded-xl bg-critical-50 px-4 py-3 text-sm text-critical-700">
              {failure} Reload to try again.
            </p>
          ) : list && list.conversations.length === 0 ? (
            <div className="py-16 text-center">
              <p className="text-sm font-medium text-gray-700">
                {status === "open" ? "Nothing needs a reply." : "No conversations here."}
              </p>
              <p className="mt-1 text-[13px] text-gray-400">
                {label === "security"
                  ? "New mail to security@ appears here as it arrives."
                  : "New mail to support@ and info@ appears here as it arrives."}
              </p>
            </div>
          ) : (
            <ul className="space-y-1" data-testid="inbox-list">
              {list?.conversations.map((c) => {
                const who = c.contact_name || c.contact_email || "Help24 member";
                const unanswered = c.status === "open";
                return (
                  <li key={c.id}>
                    <Link
                      href={`/dashboard/inbox/${c.id}`}
                      className="block rounded-xl px-4 py-3 transition-colors hover:bg-surface focus:bg-surface focus:outline-none"
                    >
                      <div className="flex items-baseline justify-between gap-3">
                        <p className={`min-w-0 truncate text-sm ${unanswered ? "font-semibold text-gray-900" : "text-gray-700"}`}>
                          {who}
                          {c.label === "general" && <span className="ml-2 text-xs font-normal text-gray-400">General</span>}
                          {c.reply_via === "app" && <span className="ml-2 text-xs font-normal text-gray-400" data-testid="row-app">App</span>}
                        </p>
                        <span className="shrink-0 text-xs text-gray-400">
                          <span
                            className={unanswered ? "font-medium text-caution-700" : "text-gray-500"}
                            data-testid="row-status"
                          >
                            {STATUS_LABELS[c.status]}
                          </span>
                          {" · "}
                          {agoLabel(Date.parse(c.last_message_at), now)}
                        </span>
                      </div>
                      <p className={`mt-0.5 truncate text-[13.5px] ${unanswered ? "font-medium text-gray-900" : "text-gray-700"}`}>
                        {c.subject}
                        <span className="ml-2 text-xs font-normal text-gray-400">{c.ref}</span>
                      </p>
                      {c.preview && (
                        <p className="mt-0.5 truncate text-[13px] text-gray-500">
                          {c.preview.author === "staff" ? "You: " : ""}
                          {c.preview.body}
                        </p>
                      )}
                    </Link>
                  </li>
                );
              })}
            </ul>
          )}
        </FilterResults>
      </div>
    </FilterScope>
  );
}
