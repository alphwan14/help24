"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { createPortal } from "react-dom";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useAlerts } from "./AlertsProvider";
import { reviewAlertAction } from "@/lib/alerts-actions";
import {
  CATEGORY_LABELS,
  PRIORITY_META,
  SOURCE_LABELS,
  fmtKesShort,
  waited,
  type AdminAlert,
  type AlertPriority,
} from "@/lib/alerts";

/**
 * The bell, where it cannot get in the way: in the navigation rail on desktop
 * and the top bar on mobile — never in page content. A number appears only for
 * unacknowledged HIGH alerts; unacknowledged MEDIUM ones show a quiet dot; LOW
 * never marks the bell at all.
 */
export default function AlertsBell({ placement }: { placement: "rail" | "topbar" }) {
  const alerts = useAlerts();
  const [open, setOpen] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  const pathname = usePathname();

  // Navigating away (usually by following an alert) closes the panel.
  useEffect(() => {
    setOpen(false);
  }, [pathname]);

  if (!alerts?.enabled) return null;
  const { urgentCount, hasUnreadMedium } = alerts;
  const label =
    urgentCount > 0
      ? `Alerts: ${urgentCount} need${urgentCount === 1 ? "s" : ""} action`
      : hasUnreadMedium
        ? "Alerts: items to review"
        : "Alerts";

  return (
    <>
      <button
        ref={button}
        type="button"
        onClick={() => {
          setOpen((o) => !o);
          if (!open) alerts.refresh();
        }}
        aria-label={label}
        aria-expanded={open}
        aria-haspopup="dialog"
        title={label}
        className={[
          "relative w-9 h-9 flex items-center justify-center rounded-lg transition-colors shrink-0",
          open ? "text-white bg-white/[0.1]" : "text-rail-400 hover:text-white hover:bg-white/[0.08]",
        ].join(" ")}
      >
        <BellIcon className="w-[18px] h-[18px]" />
        {urgentCount > 0 ? (
          <span className="absolute -top-0.5 -right-0.5 min-w-[18px] h-[18px] px-1 rounded-full bg-critical-500 text-white text-[10.5px] font-bold leading-[18px] text-center tabular-nums ring-2 ring-rail-950">
            {urgentCount > 9 ? "9+" : urgentCount}
          </span>
        ) : hasUnreadMedium ? (
          <span className="absolute top-1.5 right-1.5 w-2 h-2 rounded-full bg-caution-500 ring-2 ring-rail-950" />
        ) : null}
      </button>
      {open &&
        createPortal(
          <AlertsPanel
            placement={placement}
            onClose={() => {
              setOpen(false);
              button.current?.focus();
            }}
          />,
          document.body,
        )}
    </>
  );
}

function AlertsPanel({ placement, onClose }: { placement: "rail" | "topbar"; onClose: () => void }) {
  const alerts = useAlerts()!;
  const heading = useRef<HTMLHeadingElement>(null);
  const [showLow, setShowLow] = useState(false);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    heading.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    const tick = window.setInterval(() => setNow(Date.now()), 30_000);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      window.clearInterval(tick);
    };
  }, [onClose]);

  const list = alerts.data?.alerts ?? [];
  const tiers: AlertPriority[] = ["high", "medium", "low"];
  const unavailable = alerts.data?.unavailable ?? [];

  return (
    <>
      {/* Click-away catcher. Transparent: the panel is a glance, not a modal. */}
      <div className="fixed inset-0 z-[64]" aria-hidden onClick={onClose} />
      <div
        role="dialog"
        aria-modal="false"
        aria-labelledby="alerts-panel-title"
        className={[
          "fixed z-[65] flex flex-col bg-surface border border-gray-200 rounded-xl shadow-2xl overflow-hidden",
          placement === "rail"
            ? "left-[252px] top-3 w-[420px] max-h-[calc(100vh-24px)]"
            : "left-2 right-2 top-[60px] max-h-[calc(100vh-72px)] sm:left-auto sm:w-[420px]",
        ].join(" ")}
      >
        {/* Header */}
        <div className="flex items-center justify-between gap-3 px-4 py-3 border-b border-gray-100">
          <div>
            <h2 id="alerts-panel-title" ref={heading} tabIndex={-1} className="text-[14px] font-semibold text-gray-900 outline-none">
              Alerts
            </h2>
            <p className="text-[11.5px] text-gray-400 mt-0.5">
              {alerts.fetchedAt ? `Checked ${waited(new Date(alerts.fetchedAt).toISOString(), now) ?? "just now"} ago` : "Checking…"}
            </p>
          </div>
          <div className="flex items-center gap-1">
            <button
              type="button"
              onClick={alerts.refresh}
              disabled={alerts.loading}
              aria-label="Check again"
              title="Check again"
              className="w-8 h-8 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 disabled:opacity-50"
            >
              <RefreshIcon className={`w-4 h-4 ${alerts.loading ? "animate-spin" : ""}`} />
            </button>
            <button
              type="button"
              onClick={onClose}
              aria-label="Close alerts"
              className="w-8 h-8 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100"
            >
              <CloseIcon className="w-4 h-4" />
            </button>
          </div>
        </div>

        {/* Body */}
        <div className="flex-1 overflow-y-auto">
          {!alerts.data && alerts.error ? (
            <div className="p-4">
              <div className="rounded-lg border border-critical-200 bg-critical-50 p-3">
                <p className="text-[13px] font-semibold text-critical-700">Couldn&apos;t check for alerts</p>
                <p className="text-[12.5px] text-critical-700/90 mt-0.5">{alerts.error}</p>
                <p className="text-[11.5px] text-gray-500 mt-1.5">This is not the same as &ldquo;all clear&rdquo;.</p>
              </div>
            </div>
          ) : !alerts.data ? (
            <div className="p-4 space-y-3" aria-busy="true">
              {[0, 1, 2].map((i) => (
                <div key={i} className="h-16 rounded-lg bg-gray-100 animate-pulse" />
              ))}
            </div>
          ) : list.length === 0 ? (
            <div className="px-6 py-10 text-center">
              <div className="mx-auto w-10 h-10 rounded-full bg-positive-100 text-positive-700 flex items-center justify-center">
                <CheckIcon className="w-5 h-5" />
              </div>
              <p className="text-[13.5px] font-semibold text-gray-800 mt-3">All clear</p>
              <p className="text-[12.5px] text-gray-500 mt-1">Nothing needs attention right now.</p>
            </div>
          ) : (
            <div className="divide-y divide-gray-100">
              {tiers.map((tier) => {
                const inTier = list.filter((a) => a.priority === tier);
                if (inTier.length === 0) return null;
                const meta = PRIORITY_META[tier];
                const collapsed = tier === "low" && !showLow;
                return (
                  <section key={tier} className="px-4 py-3">
                    <div className="flex items-center justify-between gap-2">
                      <h3 className="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wide text-gray-500">
                        <span className={`w-2 h-2 rounded-full ${meta.dot}`} />
                        {meta.heading}
                        <span className="text-gray-400 normal-case tracking-normal font-medium">{inTier.length}</span>
                      </h3>
                      {tier === "low" && (
                        <button type="button" onClick={() => setShowLow((v) => !v)} className="text-[11.5px] font-semibold text-info-700 hover:underline">
                          {collapsed ? "Show" : "Hide"}
                        </button>
                      )}
                    </div>
                    {!collapsed && (
                      <>
                        <p className="text-[11px] text-gray-400 mt-0.5 mb-2">{meta.hint}</p>
                        <ul className="space-y-2">
                          {inTier.map((a) => (
                            <AlertCard key={a.id} alert={a} now={now} />
                          ))}
                        </ul>
                      </>
                    )}
                  </section>
                );
              })}
            </div>
          )}
        </div>

        {/* Honesty footer: a check that could not run is named, not hidden. */}
        {unavailable.length > 0 && (
          <div className="px-4 py-2.5 border-t border-gray-100 bg-gray-50 text-[11.5px] text-gray-500">
            Couldn&apos;t check: {unavailable.map((u) => SOURCE_LABELS[u.source] ?? u.source).join(", ")}.
            {unavailable.some((u) => u.source === "reports") && " (Reports need the Trust & Safety migrations.)"}
          </div>
        )}
      </div>
    </>
  );
}

function AlertCard({ alert: a, now }: { alert: AdminAlert; now: number }) {
  const alerts = useAlerts()!;
  const reviewed = a.review ?? null;
  const [expanded, setExpanded] = useState(false);
  const [writing, setWriting] = useState(false);
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const meta = PRIORITY_META[a.priority];
  const amount = fmtKesShort(a.amount_kes);
  const oldest = waited(a.oldest_at, now);
  // The panel carries at most five records per alert; the page has them all.
  const shown = expanded ? a.items : a.items.slice(0, 2);
  const expandable = a.items.length > 2;
  const beyond = a.count - a.items.length;

  function send(action: "reviewed" | "reopened") {
    setError(null);
    start(async () => {
      const res = await reviewAlertAction(a.id, a.fingerprint, action, action === "reviewed" ? note : undefined);
      if (!res.ok) {
        setError(res.error ?? "That did not go through.");
        // The alert changed underneath the admin: show them what is there now.
        if ((res.error ?? "").includes("changed since")) alerts.refresh();
        return;
      }
      if (res.alert) alerts.replaceAlert(res.alert);
      setWriting(false);
      setNote("");
    });
  }

  return (
    <li className={`rounded-lg border ${reviewed ? "border-gray-100" : meta.ring} bg-surface`}>
      <div className={`px-3 pt-2.5 pb-2 ${reviewed ? "opacity-70" : ""}`}>
        <div className="flex items-start justify-between gap-2">
          <p className="text-[13px] font-semibold text-gray-900 leading-snug">{a.title}</p>
          {amount && <span className="text-[12px] font-semibold text-gray-700 tabular-nums whitespace-nowrap">{amount}</span>}
        </div>
        <p className="text-[12px] text-gray-500 mt-0.5 leading-snug">{a.detail}</p>
        <p className="text-[11px] text-gray-400 mt-1">
          {CATEGORY_LABELS[a.category]}
          {oldest && <> · oldest {oldest}</>}
        </p>

        {shown.length > 0 && (
          <ul className="mt-2 space-y-1">
            {shown.map((item) => (
              <li key={item.id} className="text-[12px] leading-snug">
                {item.href ? (
                  <Link href={item.href} className="font-medium text-gray-800 hover:underline">
                    {item.label}
                  </Link>
                ) : (
                  <span className="font-medium text-gray-800">{item.label}</span>
                )}
                {item.detail && <span className="text-gray-500"> — {item.detail}</span>}
              </li>
            ))}
          </ul>
        )}
        {expandable && (
          <button type="button" onClick={() => setExpanded((v) => !v)} className="mt-1 text-[11.5px] font-semibold text-info-700 hover:underline">
            {expanded ? "Show fewer" : `+${a.items.length - 2} more`}
          </button>
        )}
        {expanded && beyond > 0 && <p className="text-[11px] text-gray-400 mt-0.5">and {beyond} more on the page</p>}
      </div>

      {/* Reviewed: quiet for every admin, with who and why — until the records change. */}
      {reviewed && (
        <div className="mx-3 mb-2 rounded-md bg-gray-50 border border-gray-100 px-2.5 py-2 text-[11.5px] text-gray-600">
          <span className="font-semibold text-gray-700">Reviewed</span> by {reviewed.admin_email}
          {waited(reviewed.at, now) && <> · {waited(reviewed.at, now)} ago</>}
          <span className="block text-gray-500 mt-0.5">&ldquo;{reviewed.note}&rdquo;</span>
        </div>
      )}

      {writing && !reviewed && (
        <div className="mx-3 mb-2 space-y-1.5">
          <textarea
            className="input resize-none !min-h-0 text-[12.5px]"
            rows={2}
            maxLength={500}
            autoFocus
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="Why does this need nothing more? e.g. Sandbox test payouts — no real money."
            aria-label="Why this needs nothing more"
          />
          <p className="text-[10.5px] text-gray-400">
            Every admin sees this. It stays reviewed until a record joins or leaves the alert.
          </p>
        </div>
      )}
      {error && <p className="mx-3 mb-2 text-[11.5px] text-critical-700">{error}</p>}

      <div className="flex items-center justify-between gap-2 px-3 py-2 border-t border-gray-100">
        {reviewed ? (
          <button type="button" disabled={pending} onClick={() => send("reopened")} className="text-[11.5px] font-medium text-gray-500 hover:text-gray-800 disabled:opacity-50">
            {pending ? "Reopening…" : "Reopen"}
          </button>
        ) : writing ? (
          <span className="flex items-center gap-3">
            <button
              type="button"
              disabled={pending || note.trim().length < 5}
              onClick={() => send("reviewed")}
              className="text-[11.5px] font-semibold text-gray-800 hover:underline disabled:opacity-40 disabled:no-underline"
            >
              {pending ? "Saving…" : "Save review"}
            </button>
            <button type="button" disabled={pending} onClick={() => { setWriting(false); setError(null); }} className="text-[11.5px] text-gray-500 hover:text-gray-800">
              Cancel
            </button>
          </span>
        ) : (
          <button
            type="button"
            onClick={() => setWriting(true)}
            className="text-[11.5px] font-medium text-gray-500 hover:text-gray-800"
            title="Quiet this for every admin, for exactly these records, with a reason"
          >
            Mark reviewed
          </button>
        )}
        <Link href={a.href} className="text-[12px] font-semibold text-info-700 hover:underline">
          {a.action} →
        </Link>
      </div>
    </li>
  );
}

// ── Icons ───────────────────────────────────────────────────────────────────

function BellIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.75} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M14.857 17.082a23.848 23.848 0 005.454-1.31A8.967 8.967 0 0118 9.75v-.7V9A6 6 0 006 9v.75a8.967 8.967 0 01-2.312 6.022c1.733.64 3.56 1.085 5.455 1.31m5.714 0a24.255 24.255 0 01-5.714 0m5.714 0a3 3 0 11-5.714 0" />
    </svg>
  );
}

function RefreshIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.75} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0l3.181 3.183a8.25 8.25 0 0013.803-3.7M4.031 9.865a8.25 8.25 0 0113.803-3.7l3.181 3.182m0-4.991v4.99" />
    </svg>
  );
}

function CloseIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
    </svg>
  );
}

function CheckIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
    </svg>
  );
}
