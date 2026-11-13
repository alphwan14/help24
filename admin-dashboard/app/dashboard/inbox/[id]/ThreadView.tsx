"use client";

import { PhotoLink, type Photo } from "@/components/PhotoViewer";

import { useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import type { ConversationStatus, SupportMessage, SupportThread } from "@/lib/support";
import { INBOXES } from "@/lib/support-inboxes";
import { addSupportNote, retrySupportReply, sendSupportReply, setSupportStatus } from "@/lib/support-actions";

const STATUS_TEXT: Record<ConversationStatus, string> = {
  open: "Needs reply",
  waiting: "Waiting on member",
  closed: "Closed",
};

function when(iso: string) {
  return new Date(iso).toLocaleString("en-KE", {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    timeZone: "Africa/Nairobi",
  });
}

/**
 * The conversation, the composer and the member, side by side on a wide
 * screen. Replies are emailed as "Help24 Support"; which admin wrote one is
 * shown here only. Internal notes are never sent.
 */
export default function ThreadView({ thread }: { thread: SupportThread }) {
  const { conversation: c, member, messages } = thread;
  const inbox = INBOXES[c.label] ?? INBOXES.support;
  // Message Help24: the member wrote from the app, and answers go back there.
  const inApp = c.reply_via === "app";
  const who = c.contact_name || member?.name || c.contact_email || "Help24 member";
  const seenAt = c.member_read_at ? Date.parse(c.member_read_at) : 0;
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [mode, setMode] = useState<"reply" | "note">("reply");
  const [text, setText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const run = (job: () => Promise<{ ok: boolean; error?: string; notSent?: string }>, after?: () => void) => {
    setError(null);
    setNotice(null);
    startTransition(async () => {
      const r = await job();
      if (!r.ok) {
        setError(r.error ?? "That did not work. Please try again.");
        return;
      }
      if (r.notSent) setError(`Saved, but the email was not sent. ${r.notSent}`);
      after?.();
      router.refresh();
    });
  };

  const submit = () => {
    if (!text.trim()) return;
    if (mode === "reply") {
      run(() => sendSupportReply(c.id, text), () => setText(""));
    } else {
      run(() => addSupportNote(c.id, text), () => {
        setText("");
        setNotice("Note added. Only staff can see it.");
      });
    }
  };

  return (
    <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_280px]">
      <div className="min-w-0 space-y-6">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <Link href="/dashboard/inbox" className="text-[13px] text-gray-500 hover:text-gray-900">
              ← Inbox
            </Link>
            <h2 className="mt-1 text-lg font-semibold text-gray-900">{c.subject}</h2>
            <p className="mt-0.5 text-[13px] text-gray-500">
              {c.ref} · {inApp ? "Support, in the app" : `${inbox.name} (${inbox.address.split("@")[0]}@)`} ·{" "}
              <span data-testid="thread-status">{STATUS_TEXT[c.status]}</span>
            </p>
          </div>
          <div className="flex gap-2">
            {c.status !== "closed" ? (
              <button type="button" className="btn-ghost" disabled={pending} onClick={() => run(() => setSupportStatus(c.id, "closed"))}>
                Close
              </button>
            ) : (
              <button type="button" className="btn-ghost" disabled={pending} onClick={() => run(() => setSupportStatus(c.id, "open"))}>
                Reopen
              </button>
            )}
            {c.status === "open" && (
              <button type="button" className="btn-ghost" disabled={pending} onClick={() => run(() => setSupportStatus(c.id, "waiting"))}>
                Mark waiting
              </button>
            )}
          </div>
        </div>

        <ol className="space-y-5" data-testid="thread-messages">
          {messages.map((m) => (
            <MessageItem
              key={m.id}
              m={m}
              contact={who}
              staffName={inbox.signature}
              seen={inApp && seenAt >= Date.parse(m.created_at)}
              onRetry={() => run(() => retrySupportReply(c.id, m.id))}
              pending={pending}
            />
          ))}
        </ol>

        <div className="rounded-xl bg-surface p-4" data-testid="composer">
          <div className="mb-3 flex gap-4 text-[13px]" role="tablist">
            {(["reply", "note"] as const).map((m) => (
              <button
                key={m}
                type="button"
                role="tab"
                aria-selected={mode === m}
                onClick={() => setMode(m)}
                className={mode === m ? "font-semibold text-gray-900" : "text-gray-500 hover:text-gray-900"}
              >
                {m === "reply" ? "Reply" : "Internal note"}
              </button>
            ))}
          </div>
          <label htmlFor="composer-text" className="sr-only">
            {mode === "reply" ? "Reply" : "Internal note"}
          </label>
          <textarea
            id="composer-text"
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if ((e.ctrlKey || e.metaKey) && e.key === "Enter") submit();
            }}
            rows={5}
            maxLength={10000}
            placeholder={mode === "reply" ? `Write to ${who}…` : "Only staff will see this."}
            className={`input resize-y ${mode === "note" ? "bg-caution-50" : ""}`}
          />
          <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
            <p className="text-xs text-gray-500">
              {mode !== "reply"
                ? "Notes are never sent."
                : inApp
                  ? `Sent to ${who} in the Help24 app as ${inbox.signature}, with a notification.`
                  : `Emailed to ${c.contact_email} from ${inbox.from}, signed ${inbox.signature}.`}
            </p>
            <button type="button" className="btn-primary ml-auto" disabled={pending || !text.trim()} onClick={submit}>
              {pending ? "Saving…" : mode === "reply" ? "Send reply" : "Add note"}
            </button>
          </div>
          {error && (
            <p role="alert" className="mt-3 text-[13px] text-critical-700">
              {error}
            </p>
          )}
          {notice && (
            <p role="status" className="mt-3 text-[13px] text-gray-600">
              {notice}
            </p>
          )}
        </div>
      </div>

      <aside className="space-y-2 text-[13px]" data-testid="member-panel">
        <p className="text-xs font-semibold uppercase tracking-wider text-gray-400">From</p>
        <p className="font-medium text-gray-900">{who}</p>
        {c.contact_email && <p className="break-all text-gray-500">{c.contact_email}</p>}
        {member ? (
          <div className="space-y-1 pt-3">
            <p className="text-xs font-semibold uppercase tracking-wider text-gray-400">Help24 account</p>
            <p className="text-gray-900">{member.name || "No name set"}</p>
            {member.phone_number && <p className="text-gray-500">{member.phone_number}</p>}
            {member.created_at && <p className="text-gray-500">Joined {new Date(member.created_at).toLocaleDateString("en-KE", { day: "numeric", month: "short", year: "numeric" })}</p>}
            <Link href={`/dashboard/users/${member.id}`} className="inline-block pt-1 font-medium text-gray-900 hover:underline">
              Open member page
            </Link>
          </div>
        ) : (
          <p className="pt-3 text-gray-500">No Help24 account uses this address.</p>
        )}
        <p className="pt-3 text-xs text-gray-400">
          {inApp
            ? "Written from the Help24 app while signed in to this account."
            : "The From line of an email can be forged. Confirm who you are talking to before changing anything on an account."}
        </p>
      </aside>
    </div>
  );
}

function MessageItem({
  m,
  contact,
  staffName,
  seen,
  onRetry,
  pending,
}: {
  m: SupportMessage;
  contact: string;
  staffName: string;
  /** An answer in the app that the member has since opened. */
  seen: boolean;
  onRetry: () => void;
  pending: boolean;
}) {
  const [full, setFull] = useState(false);
  if (m.internal) {
    return (
      <li className="rounded-xl bg-caution-50 px-4 py-3">
        <p className="text-xs text-gray-600">
          <span className="font-semibold">Internal note</span> · {m.admin_name ?? "Staff"} · {when(m.created_at)}
        </p>
        <p className="mt-1 whitespace-pre-wrap text-sm text-gray-900">{m.body}</p>
      </li>
    );
  }
  const staff = m.author === "staff";
  return (
    <li className={staff ? "pl-6 sm:pl-12" : ""}>
      <p className="text-xs text-gray-500">
        <span className="font-semibold text-gray-900">{staff ? staffName : contact}</span>
        {staff && m.admin_name ? ` · written by ${m.admin_name}` : ""} · {when(m.created_at)}
        {!staff && m.sender_verified !== true && <span className="ml-2 text-caution-700">Sender not verified</span>}
      </p>
      {m.attachments && m.attachments.length > 0 && (
        // As the app's chats show them: the photo itself, edge to edge, no frame.
        // One photo keeps its shape; several sit in a two-column album. They open
        // over the page (components/PhotoViewer.tsx). Links last an hour.
        <MessagePhotos urls={m.attachments.map((a) => a.url)} contact={contact} />
      )}
      {m.body && (
        <p className="mt-1 whitespace-pre-wrap break-words text-sm leading-relaxed text-gray-900">{full && m.full_body ? m.full_body : m.body}</p>
      )}
      <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs text-gray-500">
        {m.full_body && (
          <button type="button" className="hover:text-gray-900 hover:underline" onClick={() => setFull((v) => !v)}>
            {full ? "Show only the new part" : "Show the whole email"}
          </button>
        )}
        {/* Email attachments are not kept here, only counted; app photos show above. */}
        {m.attachment_count > 0 && m.channel === "email" && (
          <span>
            {m.attachment_count === 1 ? "1 attachment" : `${m.attachment_count} attachments`}, in the copy sent to the team inbox
          </span>
        )}
        {staff && m.delivery === "sent" && m.channel === "app" && <span>{seen ? "Delivered in the app · Seen" : "Delivered in the app"}</span>}
        {staff && m.delivery === "sent" && m.channel !== "app" && <span>Emailed</span>}
        {staff && m.delivery === "sending" && <span>Sending…</span>}
        {staff && m.delivery === "failed" && (
          <span className="text-critical-700">
            Not sent{m.delivery_error ? `: ${m.delivery_error}` : ""}{" "}
            <button type="button" className="ml-1 font-semibold underline" disabled={pending} onClick={onRetry}>
              Try again
            </button>
          </span>
        )}
      </div>
    </li>
  );
}

function MessagePhotos({ urls, contact }: { urls: string[]; contact: string }) {
  const photos: Photo[] = urls.map((src, i) => ({ src, alt: `Photo ${i + 1} from ${contact}` }));
  if (photos.length === 1) {
    return (
      <div className="mt-2" data-testid="message-photos">
        <PhotoLink photos={photos} className="inline-block overflow-hidden">
          {/* eslint-disable-next-line @next/next/no-img-element -- storage photos, not static assets */}
          <img src={photos[0].src} alt={photos[0].alt} className="block max-h-80 max-w-full rounded-xl sm:max-w-xs" loading="lazy" />
        </PhotoLink>
      </div>
    );
  }
  return (
    <div className="mt-2 grid w-full max-w-xs grid-cols-2 gap-1 overflow-hidden rounded-xl" data-testid="message-photos">
      {photos.map((p, i) => (
        <PhotoLink key={i} photos={photos} index={i} className="overflow-hidden rounded-none">
          {/* eslint-disable-next-line @next/next/no-img-element -- storage photos, not static assets */}
          <img src={p.src} alt={p.alt} className="block aspect-square w-full object-cover" loading="lazy" />
        </PhotoLink>
      ))}
    </div>
  );
}
