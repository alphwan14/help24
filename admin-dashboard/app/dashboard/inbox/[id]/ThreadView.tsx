"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import type { ConversationStatus, SupportMessage, SupportThread } from "@/lib/support";
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
              {c.ref} · {c.label === "general" ? "General (info@)" : "Support (support@)"} ·{" "}
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
            <MessageItem key={m.id} m={m} contact={c.contact_name || c.contact_email} onRetry={() => run(() => retrySupportReply(c.id, m.id))} pending={pending} />
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
            placeholder={mode === "reply" ? `Write to ${c.contact_name || c.contact_email}…` : "Only staff will see this."}
            className={`input resize-y ${mode === "note" ? "bg-caution-50" : ""}`}
          />
          <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
            <p className="text-xs text-gray-500">
              {mode === "reply"
                ? `Emailed to ${c.contact_email} from support@help24.co.ke, signed Help24 Support.`
                : "Notes are never sent."}
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
        <p className="font-medium text-gray-900">{c.contact_name || c.contact_email}</p>
        <p className="break-all text-gray-500">{c.contact_email}</p>
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
          The From line of an email can be forged. Confirm who you are talking to before changing anything on an account.
        </p>
      </aside>
    </div>
  );
}

function MessageItem({ m, contact, onRetry, pending }: { m: SupportMessage; contact: string; onRetry: () => void; pending: boolean }) {
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
        <span className="font-semibold text-gray-900">{staff ? "Help24 Support" : contact}</span>
        {staff && m.admin_name ? ` · written by ${m.admin_name}` : ""} · {when(m.created_at)}
        {!staff && m.sender_verified !== true && <span className="ml-2 text-caution-700">Sender not verified</span>}
      </p>
      <p className="mt-1 whitespace-pre-wrap break-words text-sm leading-relaxed text-gray-900">{full && m.full_body ? m.full_body : m.body}</p>
      <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs text-gray-500">
        {m.full_body && (
          <button type="button" className="hover:text-gray-900 hover:underline" onClick={() => setFull((v) => !v)}>
            {full ? "Show only the new part" : "Show the whole email"}
          </button>
        )}
        {m.attachment_count > 0 && (
          <span>
            {m.attachment_count === 1 ? "1 attachment" : `${m.attachment_count} attachments`}, in the copy sent to the team inbox
          </span>
        )}
        {staff && m.delivery === "sent" && <span>Emailed</span>}
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
