"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { startSupportConversation } from "@/lib/support-actions";
import { INBOXES } from "@/lib/support-inboxes";

export type StartFrom = "support" | "security";

const FROM_OPTIONS: StartFrom[] = ["support", "security"];

/**
 * A new conversation, started by Help24, by email from the inbox the admin
 * chooses: support@ as Help24 Support, or security@ as Help24 Security. The
 * member's reply comes back to that inbox, and the thread keeps its sender.
 */
export default function NewMessageForm({ initialEmail, initialFrom }: { initialEmail: string; initialFrom: StartFrom }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [from, setFrom] = useState<StartFrom>(initialFrom);
  const [email, setEmail] = useState(initialEmail);
  const [subject, setSubject] = useState("");
  const [body, setBody] = useState("");
  const [error, setError] = useState<string | null>(null);

  const ready = email.trim() && subject.trim() && body.trim();
  const inbox = INBOXES[from];

  return (
    <form
      className="max-w-2xl space-y-4"
      onSubmit={(e) => {
        e.preventDefault();
        if (!ready) return;
        setError(null);
        startTransition(async () => {
          const r = await startSupportConversation({ email: email.trim(), subject: subject.trim(), body, from });
          if (!r.ok || !r.conversationId) {
            setError(r.error ?? "The message could not be started.");
            return;
          }
          router.push(`/dashboard/inbox/${r.conversationId}`);
        });
      }}
    >
      <fieldset>
        <legend className="mb-1 block text-sm font-medium text-gray-700">From</legend>
        <div className="flex flex-wrap gap-x-6 gap-y-2" data-testid="new-from">
          {FROM_OPTIONS.map((f) => (
            <label key={f} className="flex cursor-pointer items-center gap-2 text-sm">
              <input
                type="radio"
                name="new-from"
                value={f}
                checked={from === f}
                onChange={() => setFrom(f)}
                className="accent-gray-900"
              />
              <span className="font-medium text-gray-900">{INBOXES[f].signature}</span>
              <span className="text-gray-500">{INBOXES[f].from}</span>
            </label>
          ))}
        </div>
      </fieldset>
      <div>
        <label htmlFor="new-email" className="mb-1 block text-sm font-medium text-gray-700">
          To
        </label>
        <input
          id="new-email"
          type="email"
          className="input"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="member@example.com"
          autoComplete="off"
          required
        />
      </div>
      <div>
        <label htmlFor="new-subject" className="mb-1 block text-sm font-medium text-gray-700">
          Subject
        </label>
        <input id="new-subject" className="input" value={subject} onChange={(e) => setSubject(e.target.value)} maxLength={200} required />
      </div>
      <div>
        <label htmlFor="new-body" className="mb-1 block text-sm font-medium text-gray-700">
          Message
        </label>
        <textarea id="new-body" className="input resize-y" rows={8} value={body} onChange={(e) => setBody(e.target.value)} maxLength={10000} required />
      </div>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-xs text-gray-500" data-testid="new-from-hint">
          Sent from {inbox.from}, signed {inbox.signature}. Replies come back to {inbox.name}.
        </p>
        <button type="submit" className="btn-primary" disabled={pending || !ready}>
          {pending ? "Sending…" : "Send"}
        </button>
      </div>
      {error && (
        <p role="alert" className="text-[13px] text-critical-700">
          {error}
        </p>
      )}
    </form>
  );
}
