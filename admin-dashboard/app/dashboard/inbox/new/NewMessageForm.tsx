"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { startSupportConversation } from "@/lib/support-actions";

/**
 * A new conversation, started by Help24. It is emailed from support@ as
 * "Help24 Support", and the member's reply comes back into the Inbox.
 */
export default function NewMessageForm({ initialEmail }: { initialEmail: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [email, setEmail] = useState(initialEmail);
  const [subject, setSubject] = useState("");
  const [body, setBody] = useState("");
  const [error, setError] = useState<string | null>(null);

  const ready = email.trim() && subject.trim() && body.trim();

  return (
    <form
      className="max-w-2xl space-y-4"
      onSubmit={(e) => {
        e.preventDefault();
        if (!ready) return;
        setError(null);
        startTransition(async () => {
          const r = await startSupportConversation({ email: email.trim(), subject: subject.trim(), body });
          if (!r.ok || !r.conversationId) {
            setError(r.error ?? "The message could not be started.");
            return;
          }
          router.push(`/dashboard/inbox/${r.conversationId}`);
        });
      }}
    >
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
        <p className="text-xs text-gray-500">Sent from support@help24.co.ke, signed Help24 Support. Replies come back here.</p>
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
