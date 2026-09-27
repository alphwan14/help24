"use client";

import { useEffect, useId, useRef } from "react";

/**
 * The dialog shell every Trust & Safety decision opens in.
 *
 * Decisions that change someone's account never happen on a single click: they
 * open here, ask for a reason, and confirm. Escape and the backdrop close it —
 * except while a request is in flight, so a half-submitted ban cannot be
 * dismissed into an unknown state.
 */
export default function Modal({
  open,
  title,
  description,
  onClose,
  busy = false,
  tone = "neutral",
  children,
  footer,
}: {
  open: boolean;
  title: string;
  description?: React.ReactNode;
  onClose: () => void;
  busy?: boolean;
  tone?: "neutral" | "danger";
  children: React.ReactNode;
  footer: React.ReactNode;
}) {
  const titleId = useId();
  const panel = useRef<HTMLDivElement>(null);
  const opener = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (!open) return;
    opener.current = document.activeElement as HTMLElement | null;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";

    // Focus the first field, so typing a reason starts immediately.
    const first = panel.current?.querySelector<HTMLElement>(
      "textarea, input:not([type=hidden]), select, button[data-autofocus]",
    );
    first?.focus();

    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape" && !busy) {
        e.preventDefault();
        onClose();
      }
      // Keep Tab inside the dialog.
      if (e.key === "Tab" && panel.current) {
        const focusable = panel.current.querySelectorAll<HTMLElement>(
          'a[href], button:not([disabled]), textarea, input, select, [tabindex]:not([tabindex="-1"])',
        );
        if (focusable.length === 0) return;
        const firstEl = focusable[0];
        const lastEl = focusable[focusable.length - 1];
        if (e.shiftKey && document.activeElement === firstEl) {
          e.preventDefault();
          lastEl.focus();
        } else if (!e.shiftKey && document.activeElement === lastEl) {
          e.preventDefault();
          firstEl.focus();
        }
      }
    }
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = previousOverflow;
      opener.current?.focus?.();
    };
  }, [open, busy, onClose]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-[70] flex items-end sm:items-center justify-center p-0 sm:p-4">
      <div
        aria-hidden
        className="absolute inset-0 bg-black/50 backdrop-blur-[2px]"
        onClick={() => !busy && onClose()}
      />
      <div
        ref={panel}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        className={[
          "relative w-full sm:max-w-lg max-h-[92vh] overflow-y-auto",
          "bg-surface rounded-t-2xl sm:rounded-2xl shadow-2xl border",
          tone === "danger" ? "border-critical-200" : "border-gray-200",
        ].join(" ")}
      >
        <div className="px-5 pt-5 pb-3 border-b border-gray-100">
          <h2 id={titleId} className="text-[15px] font-semibold text-gray-900">
            {title}
          </h2>
          {description && <div className="text-[13px] text-gray-500 mt-1 leading-relaxed">{description}</div>}
        </div>
        <div className="px-5 py-4 space-y-4">{children}</div>
        <div className="px-5 py-3 border-t border-gray-100 bg-gray-50/60 flex flex-col-reverse sm:flex-row sm:justify-end gap-2 rounded-b-2xl">
          {footer}
        </div>
      </div>
    </div>
  );
}

/** A labelled field with its hint, used by every dialog. */
export function Field({
  label,
  hint,
  required,
  children,
}: {
  label: string;
  hint?: string;
  required?: boolean;
  children: React.ReactNode;
}) {
  return (
    <label className="block">
      <span className="text-xs font-semibold text-gray-600">
        {label}
        {required && <span className="text-critical-600"> *</span>}
      </span>
      <div className="mt-1">{children}</div>
      {hint && <span className="block text-[11.5px] text-gray-400 mt-1 leading-snug">{hint}</span>}
    </label>
  );
}
