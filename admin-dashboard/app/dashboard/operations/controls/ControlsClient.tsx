"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Modal, { Field } from "@/components/moderation/Modal";
import {
  CONTROL_TITLES,
  DEFAULT_STORE_URL,
  PICKUP_NOTE,
  SWITCHES,
  controlProblems,
  controlValue,
  describeChange,
  isRestrictive,
  nextAnnouncementId,
  type Announcement,
  type ClientConfig,
  type ControlKey,
  type KillSwitches,
  type Maintenance,
  type MinVersion,
} from "@/lib/app-controls";
import { saveAppControlAction } from "@/lib/config-actions";

export type HistoryEntry = {
  id: string;
  key: string;
  previous_value: Record<string, unknown> | null;
  new_value: Record<string, unknown>;
  reason: string;
  admin_email: string;
  admin_role: string;
  created_at: string;
};

type Latest = { version: string; publishedAt: string } | null;
type Pending = { key: ControlKey; before: Record<string, unknown>; after: Record<string, unknown> };

function fmtWhen(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-KE", {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    timeZone: "Africa/Nairobi",
  });
}

function same(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

export default function ControlsClient({
  config,
  canEdit,
  latest,
  history,
  historyAvailable,
  updatedAt,
}: {
  config: ClientConfig;
  canEdit: boolean;
  latest: Latest;
  history: HistoryEntry[];
  historyAvailable: boolean;
  updatedAt: Partial<Record<ControlKey, string>>;
}) {
  const [pending, setPending] = useState<Pending | null>(null);
  const [notice, setNotice] = useState<{ tone: "ok" | "warn"; text: string } | null>(null);

  function review(key: ControlKey, after: Record<string, unknown>) {
    setNotice(null);
    setPending({ key, before: controlValue(config, key), after });
  }

  function lastChange(key: ControlKey): string {
    const h = history.find((e) => e.key === key);
    if (h) return `Changed ${fmtWhen(h.created_at)} by ${h.admin_email}`;
    if (updatedAt[key]) return `Changed ${fmtWhen(updatedAt[key])}`;
    return "Never changed — the app's built-in default";
  }

  const shared = { canEdit, review, latest };

  return (
    <div className="space-y-5" data-testid="app-controls">
      {notice && (
        <div
          role="status"
          className={`p-3 rounded-lg border text-[13px] ${
            notice.tone === "ok" ? "bg-positive-50 border-positive-200 text-positive-700" : "bg-caution-50 border-caution-200 text-caution-700"
          }`}
        >
          {notice.text}
        </div>
      )}
      <p className="text-[13px] text-gray-500">
        {PICKUP_NOTE}
        {!canEdit && " Only a Senior Admin can change them."}
      </p>

      <div className="grid gap-4 lg:grid-cols-2">
        <FeaturesCard key={JSON.stringify(config.ops.kill_switches)} value={config.ops.kill_switches} last={lastChange("ops.kill_switches")} {...shared} />
        <VersionCard key={JSON.stringify(config.ops.min_version)} value={config.ops.min_version} last={lastChange("ops.min_version")} {...shared} />
        <MaintenanceCard key={JSON.stringify(config.ops.maintenance)} value={config.ops.maintenance} last={lastChange("ops.maintenance")} {...shared} />
        <AnnouncementCard key={JSON.stringify(config.ops.announcement)} value={config.ops.announcement} last={lastChange("ops.announcement")} {...shared} />
      </div>

      <HistoryCard history={history} available={historyAvailable} />

      <ConfirmDialog
        pending={pending}
        latest={latest}
        onClose={() => setPending(null)}
        onSaved={(recorded) => {
          setNotice(
            recorded
              ? { tone: "ok", text: "Saved, and added to the change history below." }
              : { tone: "warn", text: "Saved — but it could not be added to the change history (migration 125 is not applied yet)." },
          );
          setPending(null);
        }}
      />
    </div>
  );
}

// ── cards ───────────────────────────────────────────────────────────────────

type CardProps<T> = {
  value: T;
  last: string;
  canEdit: boolean;
  latest: Latest;
  review: (key: ControlKey, after: Record<string, unknown>) => void;
};

function ControlCard({
  title,
  status,
  last,
  children,
  dirty,
  canEdit,
  onReview,
  onReset,
}: {
  title: string;
  status: React.ReactNode;
  last: string;
  children: React.ReactNode;
  dirty: boolean;
  canEdit: boolean;
  onReview: () => void;
  onReset: () => void;
}) {
  return (
    <section className="card p-5 flex flex-col gap-4" aria-label={title}>
      <header className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-[15px] font-semibold text-gray-900">{title}</h2>
          <p className="text-[11.5px] text-gray-400 mt-0.5">{last}</p>
        </div>
        {status}
      </header>
      <div className="space-y-3 flex-1">{children}</div>
      {canEdit && (
        <div className="flex gap-2 justify-end">
          {dirty && (
            <button type="button" className="btn-ghost" onClick={onReset}>
              Undo
            </button>
          )}
          <button type="button" className="btn-primary" disabled={!dirty} onClick={onReview}>
            Review change
          </button>
        </div>
      )}
    </section>
  );
}

function Switch({
  checked,
  onChange,
  disabled,
  label,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
  label: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className={`relative inline-flex h-6 w-11 shrink-0 items-center rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-60 ${
        checked ? "bg-positive-500" : "bg-gray-300"
      }`}
    >
      <span className={`inline-block h-5 w-5 rounded-full bg-white shadow transition-transform ${checked ? "translate-x-5" : "translate-x-0.5"}`} />
    </button>
  );
}

function Pill({ tone, children }: { tone: "ok" | "off" | "warn" | "muted"; children: React.ReactNode }) {
  const cls = {
    ok: "bg-positive-100 text-positive-700",
    off: "bg-critical-100 text-critical-700",
    warn: "bg-caution-100 text-caution-700",
    muted: "bg-gray-100 text-gray-500",
  }[tone];
  return <span className={`badge whitespace-nowrap ${cls}`}>{children}</span>;
}

function FeaturesCard({ value, last, canEdit, review }: CardProps<KillSwitches>) {
  const [draft, setDraft] = useState(value);
  const off = SWITCHES.filter((s) => !value[s.key]);
  return (
    <ControlCard
      title={CONTROL_TITLES["ops.kill_switches"]}
      status={off.length ? <Pill tone="off">{off.length} off</Pill> : <Pill tone="ok">All on</Pill>}
      last={last}
      dirty={!same(draft, value)}
      canEdit={canEdit}
      onReset={() => setDraft(value)}
      onReview={() => review("ops.kill_switches", draft)}
    >
      <ul className="divide-y divide-gray-100">
        {SWITCHES.map((s) => (
          <li key={s.key} className="flex items-center justify-between gap-4 py-2.5 first:pt-0 last:pb-0">
            <div className="min-w-0">
              <p className="text-sm font-medium text-gray-800">{s.label}</p>
              <p className="text-[11.5px] text-gray-400 leading-snug">{draft[s.key] ? "On" : `Off — ${s.off}`}</p>
            </div>
            <Switch
              label={s.label}
              checked={draft[s.key]}
              disabled={!canEdit}
              onChange={(v) => setDraft({ ...draft, [s.key]: v })}
            />
          </li>
        ))}
      </ul>
    </ControlCard>
  );
}

function VersionCard({ value, last, canEdit, review, latest }: CardProps<MinVersion>) {
  // An empty store_url falls back to the app's compiled link; the form shows
  // the real page instead, and only a change the admin makes counts as one.
  const base: MinVersion = { ...value, store_url: value.store_url || DEFAULT_STORE_URL };
  const [draft, setDraft] = useState<MinVersion>(base);
  const problems = controlProblems("ops.min_version", draft, latest?.version ?? null);
  const dirty = !same(draft, base);
  return (
    <ControlCard
      title={CONTROL_TITLES["ops.min_version"]}
      status={
        <Pill tone="muted">
          {latest ? `Newest release ${latest.version}` : "Newest release unknown"}
        </Pill>
      }
      last={last}
      dirty={dirty && problems.length === 0}
      canEdit={canEdit}
      onReset={() => setDraft(base)}
      onReview={() => review("ops.min_version", { ...draft, soft: draft.soft.trim(), hard: draft.hard.trim(), store_url: draft.store_url.trim() })}
    >
      <div className="grid grid-cols-2 gap-3">
        <Field label="Suggest update below" hint="A banner with an Update button. Can be dismissed.">
          <input name="soft" className="input font-tabular" placeholder="none" value={draft.soft} disabled={!canEdit} onChange={(e) => setDraft({ ...draft, soft: e.target.value })} />
        </Field>
        <Field label="Require update below" hint="Blocks the app at its next start until updated.">
          <input name="hard" className="input font-tabular" placeholder="none" value={draft.hard} disabled={!canEdit} onChange={(e) => setDraft({ ...draft, hard: e.target.value })} />
        </Field>
      </div>
      <Field label="Message">
        <textarea className="input min-h-[64px]" maxLength={200} value={draft.message} disabled={!canEdit} onChange={(e) => setDraft({ ...draft, message: e.target.value })} />
      </Field>
      <Field label="Update button opens">
        <input className="input" value={draft.store_url} disabled={!canEdit} onChange={(e) => setDraft({ ...draft, store_url: e.target.value })} />
      </Field>
      {problems.length > 0 && (
        <ul className="text-[12.5px] text-critical-700 space-y-1" role="alert">
          {problems.map((p) => (
            <li key={p}>{p}</li>
          ))}
        </ul>
      )}
    </ControlCard>
  );
}

function MaintenanceCard({ value, last, canEdit, review, latest }: CardProps<Maintenance>) {
  const [draft, setDraft] = useState(value);
  const problems = controlProblems("ops.maintenance", draft, latest?.version ?? null);
  return (
    <ControlCard
      title={CONTROL_TITLES["ops.maintenance"]}
      status={value.active && value.message.trim() ? <Pill tone="warn">Showing</Pill> : <Pill tone="muted">Off</Pill>}
      last={last}
      dirty={!same(draft, value) && problems.length === 0}
      canEdit={canEdit}
      onReset={() => setDraft(value)}
      onReview={() => review("ops.maintenance", { ...draft, message: draft.message.trim() })}
    >
      <ToggleRow label="Show the maintenance banner" checked={draft.active} disabled={!canEdit} onChange={(active) => setDraft({ ...draft, active })} />
      <Field label="Message" hint="A warning-coloured banner at the top of the app. It does not block anything — use Features for that.">
        <textarea className="input min-h-[64px]" maxLength={200} value={draft.message} disabled={!canEdit} onChange={(e) => setDraft({ ...draft, message: e.target.value })} />
      </Field>
      {problems.map((p) => (
        <p key={p} className="text-[12.5px] text-critical-700" role="alert">{p}</p>
      ))}
    </ControlCard>
  );
}

function AnnouncementCard({ value, last, canEdit, review, latest }: CardProps<Announcement>) {
  const [draft, setDraft] = useState(value);
  const problems = controlProblems("ops.announcement", draft, latest?.version ?? null);
  const showing = value.active && !!value.id.trim() && !!value.message.trim();
  return (
    <ControlCard
      title={CONTROL_TITLES["ops.announcement"]}
      status={showing ? <Pill tone="ok">Showing</Pill> : <Pill tone="muted">Off</Pill>}
      last={last}
      dirty={!same(draft, value) && problems.length === 0}
      canEdit={canEdit}
      onReset={() => setDraft(value)}
      onReview={() => {
        const message = draft.message.trim();
        // New words, or switched back on: a new id, so people who closed the
        // previous one see this one.
        const fresh = message !== value.message.trim() || (draft.active && !value.active) || !value.id;
        review("ops.announcement", { ...draft, message, url: draft.url.trim(), id: fresh ? nextAnnouncementId() : value.id });
      }}
    >
      <ToggleRow label="Show the announcement" checked={draft.active} disabled={!canEdit} onChange={(active) => setDraft({ ...draft, active })} />
      <Field label="Message" hint="Each person can close it once; new wording shows again to everyone.">
        <textarea className="input min-h-[64px]" maxLength={200} value={draft.message} disabled={!canEdit} onChange={(e) => setDraft({ ...draft, message: e.target.value })} />
      </Field>
      <Field label="Link (optional)">
        <input className="input" placeholder="https://help24.co.ke/…" value={draft.url} disabled={!canEdit} onChange={(e) => setDraft({ ...draft, url: e.target.value })} />
      </Field>
      {problems.map((p) => (
        <p key={p} className="text-[12.5px] text-critical-700" role="alert">{p}</p>
      ))}
    </ControlCard>
  );
}

function ToggleRow({ label, checked, disabled, onChange }: { label: string; checked: boolean; disabled: boolean; onChange: (v: boolean) => void }) {
  return (
    <div className="flex items-center justify-between gap-4">
      <span className="text-sm font-medium text-gray-800">{label}</span>
      <Switch label={label} checked={checked} disabled={disabled} onChange={onChange} />
    </div>
  );
}

// ── confirm ─────────────────────────────────────────────────────────────────

function BannerPreview({ message, action, tone }: { message: string; action?: string; tone: "warn" | "info" }) {
  return (
    <div>
      <p className="text-xs font-semibold text-gray-600 mb-1">What people will see</p>
      <div
        className={`flex items-center gap-3 rounded-xl px-3.5 py-2.5 text-[13px] ${
          tone === "warn" ? "bg-caution-50 text-caution-800 border border-caution-200" : "bg-info-50 text-info-800 border border-info-200"
        }`}
      >
        <span className="flex-1 leading-snug">{message}</span>
        {action && <span className="rounded-full bg-surface px-3 py-1 text-xs font-semibold text-gray-800 border border-gray-200">{action}</span>}
      </div>
    </div>
  );
}

function consequence(p: Pending): string | null {
  if (p.key === "ops.kill_switches") {
    const off = SWITCHES.filter((s) => p.before[s.key] !== false && p.after[s.key] === false);
    return off.length ? off.map((s) => s.off).join(" ") : null;
  }
  if (p.key === "ops.min_version" && isRestrictive(p.key, p.before, p.after)) {
    return `Anyone on a version below ${String(p.after.hard)} will be blocked at their next app start until they install the update from ${String(p.after.store_url)}.`;
  }
  return null;
}

function ConfirmDialog({
  pending,
  latest,
  onClose,
  onSaved,
}: {
  pending: Pending | null;
  latest: Latest;
  onClose: () => void;
  onSaved: (recorded: boolean) => void;
}) {
  const router = useRouter();
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, startTransition] = useTransition();

  if (!pending) return null;
  const lines = describeChange(pending.key, pending.before, pending.after);
  const danger = isRestrictive(pending.key, pending.before, pending.after);
  const why = consequence(pending);
  const problems = controlProblems(pending.key, pending.after, latest?.version ?? null);

  const after = pending.after as Record<string, string | boolean>;
  const preview =
    pending.key === "ops.maintenance" && after.active
      ? <BannerPreview tone="warn" message={String(after.message)} />
      : pending.key === "ops.announcement" && after.active
        ? <BannerPreview tone="info" message={String(after.message)} action={after.url ? "Learn more" : undefined} />
        : pending.key === "ops.min_version" && after.soft
          ? <BannerPreview tone="info" message={String(after.message) || "A newer version of Help24 is available."} action="Update" />
          : null;

  function close() {
    setReason("");
    setError(null);
    onClose();
  }

  function confirm() {
    setError(null);
    const key = pending!.key;
    const value = pending!.after;
    startTransition(async () => {
      const res = await saveAppControlAction(key, value, reason);
      if (!res.ok) {
        setError(res.error ?? "Could not save.");
        return;
      }
      setReason("");
      onSaved(res.recorded !== false);
      router.refresh();
    });
  }

  return (
    <Modal
      open
      title={`Change ${CONTROL_TITLES[pending.key].toLowerCase()}`}
      description="This changes the app for everyone. Check it, say why, and confirm."
      tone={danger ? "danger" : "neutral"}
      busy={busy}
      onClose={close}
      footer={
        <>
          <button type="button" className="btn-ghost" disabled={busy} onClick={close}>
            Cancel
          </button>
          <button
            type="button"
            className={danger ? "btn-primary !bg-critical-600 hover:!bg-critical-700" : "btn-primary"}
            disabled={busy || reason.trim().length < 5 || problems.length > 0 || lines.length === 0}
            onClick={confirm}
          >
            {busy ? "Saving…" : "Confirm change"}
          </button>
        </>
      }
    >
      <ul className="text-sm text-gray-800 space-y-1 font-tabular" data-testid="change-lines">
        {lines.length ? lines.map((l) => <li key={l}>{l}</li>) : <li className="text-gray-400">Nothing changes.</li>}
      </ul>
      {why && <p className="p-3 rounded-lg bg-critical-50 border border-critical-200 text-[12.5px] text-critical-700">{why}</p>}
      {preview}
      <Field label="Why" required hint="Recorded with the change, with your name.">
        <textarea className="input min-h-[72px]" maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
      </Field>
      {problems.map((p) => (
        <p key={p} className="text-[12.5px] text-critical-700" role="alert">{p}</p>
      ))}
      {error && <p className="p-3 rounded-lg bg-critical-50 border border-critical-200 text-[12.5px] text-critical-700" role="alert">{error}</p>}
    </Modal>
  );
}

// ── history ─────────────────────────────────────────────────────────────────

function HistoryCard({ history, available }: { history: HistoryEntry[]; available: boolean }) {
  return (
    <section className="card p-5" aria-label="Change history">
      <h2 className="text-[15px] font-semibold text-gray-900">Change history</h2>
      {!available ? (
        <p className="text-[13px] text-gray-500 mt-2">
          The change history is not available yet. Changes still apply; they are recorded once migration 125 is applied.
        </p>
      ) : history.length === 0 ? (
        <p className="text-[13px] text-gray-500 mt-2">No changes made from the dashboard yet.</p>
      ) : (
        <ol className="mt-3 divide-y divide-gray-100">
          {history.map((h) => {
            const key = h.key as ControlKey;
            const lines = CONTROL_TITLES[key] ? describeChange(key, h.previous_value ?? {}, h.new_value) : [h.key];
            return (
              <li key={h.id} className="py-3 first:pt-0 last:pb-0 text-[13px]">
                <div className="flex flex-wrap items-baseline justify-between gap-x-3">
                  <span className="font-medium text-gray-900">{CONTROL_TITLES[key] ?? h.key}</span>
                  <span className="text-[11.5px] text-gray-400 font-tabular">{fmtWhen(h.created_at)}</span>
                </div>
                <ul className="text-gray-700 mt-0.5">
                  {(lines.length ? lines : ["Saved with no change"]).map((l) => (
                    <li key={l}>{l}</li>
                  ))}
                </ul>
                <p className="text-gray-500 mt-1">
                  “{h.reason}” — {h.admin_email}
                </p>
              </li>
            );
          })}
        </ol>
      )}
    </section>
  );
}
