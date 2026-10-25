"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import type { LinkCandidate, UnlinkedLogin } from "@/lib/api";
import { linkDashboardLogin } from "@/lib/admin-actions";
import PersonPicker from "@/components/PersonPicker";

function fmt(iso: string | null) {
  if (!iso) return "never";
  return new Date(iso).toLocaleString("en-KE", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });
}

/**
 * Logins whose password works but which the dashboard refuses, because nobody
 * has said which Help24 person they belong to. The admin alert
 * `dashboard_login_unlinked` opens this panel (#unlinked-logins).
 */
export default function UnlinkedLogins({ logins }: { logins: UnlinkedLogin[] }) {
  if (logins.length === 0) return null;
  return (
    <section id="unlinked-logins" className="card p-5 space-y-4 scroll-mt-6">
      <div>
        <h2 className="text-base font-bold text-gray-900">Logins waiting to be linked</h2>
        <p className="text-sm text-gray-500 mt-1">
          These people can sign in, but the dashboard turns them away until you say which Help24 account each
          login belongs to. Only link a login to someone you have confirmed is the same person.
        </p>
      </div>
      <ul className="divide-y divide-gray-100">
        {logins.map((l) => (
          <LoginRow key={l.auth_subject} login={l} />
        ))}
      </ul>
    </section>
  );
}

function LoginRow({ login }: { login: UnlinkedLogin }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [person, setPerson] = useState<LinkCandidate | null>(null);
  const [message, setMessage] = useState<{ kind: "ok" | "error"; text: string } | null>(null);
  const [pending, startTransition] = useTransition();

  function link() {
    if (!person) return;
    startTransition(async () => {
      const res = await linkDashboardLogin(login.auth_subject, person.id);
      if (!res.ok) {
        setMessage({ kind: "error", text: res.error ?? "Could not link this login." });
        return;
      }
      setMessage({
        kind: "ok",
        text: res.data?.can_sign_in
          ? "Linked. They can sign in now."
          : "Linked — but this Help24 account is not an admin yet, so they still can't open the dashboard. Use Make Admin on the Users page.",
      });
      router.refresh();
    });
  }

  return (
    <li className="py-3 space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="min-w-0">
          <p className="text-sm font-medium text-gray-900 truncate">{login.email ?? "Login with no email"}</p>
          <p className="text-xs text-gray-500">
            Last signed in {fmt(login.last_sign_in_at)} · created {fmt(login.created_at)}
          </p>
        </div>
        {!open && (
          <button type="button" onClick={() => setOpen(true)} className="btn-primary text-sm">
            Link to a Help24 account
          </button>
        )}
      </div>
      {open && (
        <div className="space-y-3 rounded-lg border border-gray-100 p-3">
          <PersonPicker selected={person} onSelect={setPerson} />
          <div className="flex items-center gap-2">
            <button type="button" onClick={link} disabled={!person || pending} className="btn-primary text-sm disabled:opacity-50">
              {pending ? "Linking…" : "Link this login"}
            </button>
            <button type="button" onClick={() => { setOpen(false); setPerson(null); setMessage(null); }} className="text-sm text-gray-500 hover:text-gray-800">
              Cancel
            </button>
          </div>
        </div>
      )}
      {message && (
        <p className={`text-sm ${message.kind === "ok" ? "text-green-700" : "text-red-600"}`}>{message.text}</p>
      )}
    </li>
  );
}
