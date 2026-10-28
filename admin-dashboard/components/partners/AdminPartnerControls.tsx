"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Modal, { Field } from "@/components/moderation/Modal";
import CopyButton from "./CopyButton";
import { createPartnerAgentAction, issuePartnerInviteAction, setPartnerStatusAction } from "@/lib/partner-admin-actions";

function fmt(iso: string): string {
  return new Date(iso).toLocaleString("en-KE", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit", timeZone: "Africa/Nairobi" });
}

/** The one-time invitation link, with ways to send it. It is never shown again. */
function InviteLink({ url, expiresAt, name }: { url: string; expiresAt?: string; name: string }) {
  const text = `Hi ${name}, here is your Help24 partner invitation. Open it to set your password: ${url}`;
  return (
    <div className="rounded-lg border border-positive-200 bg-positive-50 p-3 text-[12.5px] space-y-2" data-testid="invite-link">
      <p className="font-semibold text-positive-700">Invitation link — copy it now, it is shown only once</p>
      <p className="font-mono break-all text-gray-800">{url}</p>
      {expiresAt && <p className="text-gray-500">Works once, until {fmt(expiresAt)}.</p>}
      <div className="flex flex-wrap gap-2">
        <CopyButton value={url} label="Copy link" />
        <a className="btn-ghost border border-gray-200" href={`https://wa.me/?text=${encodeURIComponent(text)}`} target="_blank" rel="noopener noreferrer">
          Send on WhatsApp
        </a>
      </div>
    </div>
  );
}

export function CreateAgent() {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ name: "", kind: "onboarding", email: "", phone: "" });
  const [error, setError] = useState<string | null>(null);
  const [made, setMade] = useState<{ id: string; code: string; inviteUrl?: string; expiresAt?: string; name: string } | null>(null);
  const [busy, start] = useTransition();

  function close() {
    setOpen(false);
    setError(null);
    if (made) router.push(`/dashboard/partners/${made.id}`);
    setMade(null);
    setForm({ name: "", kind: "onboarding", email: "", phone: "" });
  }

  function submit() {
    setError(null);
    start(async () => {
      const res = await createPartnerAgentAction(form);
      if (!res.ok) return setError(res.error ?? "Could not add the agent.");
      setMade({ id: res.id!, code: res.code!, inviteUrl: res.inviteUrl, expiresAt: res.expiresAt, name: form.name.trim() });
      if (res.error) setError(res.error);
      // No router.refresh() here: "Done" navigates to the new agent's page, and
      // a refresh still in flight could swallow that navigation (seen in e2e).
      // The list is revalidated on the server (revalidatePath) for next time.
    });
  }

  return (
    <>
      <button type="button" className="btn-primary" onClick={() => setOpen(true)}>
        Add agent
      </button>
      <Modal
        open={open}
        title={made ? `${made.name} is set up` : "Add a partner agent"}
        description={made ? undefined : "They get an agent code straight away, and an invitation to their own partner sign-in."}
        busy={busy}
        onClose={close}
        footer={
          made ? (
            <button type="button" className="btn-primary" onClick={close}>Done</button>
          ) : (
            <>
              <button type="button" className="btn-ghost" disabled={busy} onClick={close}>Cancel</button>
              <button type="button" className="btn-primary" disabled={busy || form.name.trim().length < 2} onClick={submit}>
                {busy ? "Adding…" : "Add agent"}
              </button>
            </>
          )
        }
      >
        {made ? (
          <div className="space-y-3">
            <p className="text-sm text-gray-700">
              Agent code <span className="font-mono font-bold text-gray-900">{made.code}</span>
            </p>
            {made.inviteUrl ? (
              <InviteLink url={made.inviteUrl} expiresAt={made.expiresAt} name={made.name} />
            ) : (
              <p className="text-[12.5px] text-gray-500">No email was given, so there is no sign-in yet. Add one and invite them from their page.</p>
            )}
          </div>
        ) : (
          <>
            <Field label="Name" required hint="Shown to members when they enter the code.">
              <input className="input" value={form.name} maxLength={80} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            </Field>
            <Field label="Kind">
              <select className="input" value={form.kind} onChange={(e) => setForm({ ...form, kind: e.target.value })}>
                <option value="onboarding">Onboarding — signs people up in person</option>
                <option value="marketing">Marketing — shares links and QR codes</option>
                <option value="research">Research — reads market totals</option>
              </select>
            </Field>
            <Field label="Email" hint="Their partner sign-in. Must not already be used by another Help24 login.">
              <input className="input" type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
            </Field>
            <Field label="Phone" hint="Used to stop an agent crediting themselves.">
              <input className="input" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
            </Field>
          </>
        )}
        {error && <p role="alert" className="p-3 rounded-lg bg-critical-50 border border-critical-200 text-[12.5px] text-critical-700">{error}</p>}
      </Modal>
    </>
  );
}

export function AgentControls({ agentId, name, status, hasEmail }: { agentId: string; name: string; status: string; hasEmail: boolean }) {
  const router = useRouter();
  const [invite, setInvite] = useState<{ url: string; expiresAt?: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [statusOpen, setStatusOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [busy, start] = useTransition();
  const suspending = status === "active";

  function sendInvite() {
    setError(null);
    start(async () => {
      const res = await issuePartnerInviteAction(agentId);
      if (!res.ok) return setError(res.error ?? "Could not create the invitation.");
      setInvite({ url: res.inviteUrl!, expiresAt: res.expiresAt });
      router.refresh();
    });
  }

  function changeStatus() {
    setError(null);
    start(async () => {
      const res = await setPartnerStatusAction(agentId, suspending ? "suspended" : "active", reason);
      if (!res.ok) return setError(res.error ?? "Could not change the status.");
      setStatusOpen(false);
      setReason("");
      router.refresh();
    });
  }

  return (
    <section className="card p-4 space-y-3" aria-label="Agent access">
      <h2 className="text-[14px] font-semibold text-gray-900">Access</h2>
      <div className="flex flex-wrap gap-2">
        <button type="button" className="btn-ghost border border-gray-200" disabled={busy || !hasEmail || !suspending} onClick={sendInvite}>
          New invitation link
        </button>
        <button
          type="button"
          className={suspending ? "btn-ghost border border-critical-200 text-critical-700" : "btn-ghost border border-gray-200"}
          disabled={busy}
          onClick={() => setStatusOpen(true)}
        >
          {suspending ? "Pause agent" : "Reactivate agent"}
        </button>
      </div>
      <p className="text-[11.5px] text-gray-400">
        A new invitation also resets their password. Pausing stops their code being accepted and signs them out of the portal;
        members already credited stay credited.
      </p>
      {invite && <InviteLink url={invite.url} expiresAt={invite.expiresAt} name={name} />}
      {error && <p role="alert" className="text-[12.5px] text-critical-700">{error}</p>}

      <Modal
        open={statusOpen}
        title={suspending ? `Pause ${name}` : `Reactivate ${name}`}
        description={suspending ? "Their code stops working for new members and they can't sign in to the portal." : "Their code works again and they can sign in."}
        tone={suspending ? "danger" : "neutral"}
        busy={busy}
        onClose={() => setStatusOpen(false)}
        footer={
          <>
            <button type="button" className="btn-ghost" disabled={busy} onClick={() => setStatusOpen(false)}>Cancel</button>
            <button type="button" className="btn-primary" disabled={busy || reason.trim().length < 5} onClick={changeStatus}>
              {busy ? "Saving…" : "Confirm"}
            </button>
          </>
        }
      >
        <Field label="Why" required hint="Recorded with your name.">
          <textarea className="input min-h-[72px]" maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
        </Field>
        {error && <p role="alert" className="text-[12.5px] text-critical-700">{error}</p>}
      </Modal>
    </section>
  );
}
