"use client";

import { forwardRef, useId, useState } from "react";
import {
  PASSWORD_MIN_LENGTH,
  STRENGTH_LABELS,
  passwordStrength,
  type Requirement,
} from "@/lib/admin-password";

/**
 * The password inputs shared by Settings (change) and /reset-password (set).
 * The rules and the meter's scoring live in lib/admin-password.ts; these only
 * draw them.
 */

export function EyeIcon({ open }: { open: boolean }) {
  return open ? (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} className="w-4 h-4" aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M2.036 12.322a1.012 1.012 0 010-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178z" />
      <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
    </svg>
  ) : (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} className="w-4 h-4" aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M3.98 8.223A10.477 10.477 0 001.934 12C3.226 16.338 7.244 19.5 12 19.5c.993 0 1.953-.138 2.863-.395M6.228 6.228A10.45 10.45 0 0112 4.5c4.756 0 8.773 3.162 10.065 7.498a10.522 10.522 0 01-4.293 5.774M6.228 6.228L3 3m3.228 3.228l3.65 3.65m7.894 7.894L21 21m-3.228-3.228l-3.65-3.65m0 0a3 3 0 10-4.243-4.243m4.243 4.243L9.88 9.88" />
    </svg>
  );
}

type PasswordFieldProps = {
  label: string;
  name: string;
  value: string;
  onChange: (value: string) => void;
  autoComplete: "current-password" | "new-password";
  error?: string;
  /** Id of hint content rendered below (meter, checklist), announced with the field. */
  describedBy?: string;
  disabled?: boolean;
  children?: React.ReactNode;
};

/**
 * One labelled password input with its own show/hide toggle. Showing one field
 * never reveals the others. Remount it (change its `key`) to hide it again.
 */
export const PasswordField = forwardRef<HTMLInputElement, PasswordFieldProps>(function PasswordField(
  { label, name, value, onChange, autoComplete, error, describedBy, disabled, children },
  ref,
) {
  const id = useId();
  const errorId = `${id}-error`;
  const [visible, setVisible] = useState(false);
  // Caps Lock is the commonest reason a right password is refused; say so
  // while it is on, rather than after the attempt fails.
  const [capsOn, setCapsOn] = useState(false);
  const readCaps = (e: React.KeyboardEvent<HTMLInputElement>) => setCapsOn(e.getModifierState("CapsLock"));
  const described = [error ? errorId : null, describedBy].filter(Boolean).join(" ") || undefined;

  return (
    <div>
      <label htmlFor={id} className="block text-sm font-medium text-gray-700 mb-1">
        {label}
      </label>
      <div className="relative">
        <input
          ref={ref}
          id={id}
          name={name}
          type={visible ? "text" : "password"}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          autoComplete={autoComplete}
          autoCapitalize="off"
          autoCorrect="off"
          spellCheck={false}
          disabled={disabled}
          onKeyDown={readCaps}
          onKeyUp={readCaps}
          onBlur={() => setCapsOn(false)}
          aria-invalid={error ? true : undefined}
          aria-describedby={described}
          className={`input pr-11 disabled:opacity-60 ${error ? "border-red-400" : ""}`}
        />
        <button
          type="button"
          onClick={() => setVisible((v) => !v)}
          disabled={disabled}
          aria-label={visible ? `Hide ${label.toLowerCase()}` : `Show ${label.toLowerCase()}`}
          aria-pressed={visible}
          aria-controls={id}
          className="absolute inset-y-0 right-0 flex items-center px-3 text-gray-400 hover:text-gray-600 disabled:opacity-50"
        >
          <EyeIcon open={visible} />
        </button>
      </div>
      {capsOn && <p className="mt-1.5 text-xs font-medium text-caution-700">Caps Lock is on</p>}
      {error && (
        <p id={errorId} className="mt-1.5 text-xs font-medium text-red-600">
          {error}
        </p>
      )}
      {children}
    </div>
  );
});

const BAR = ["bg-red-500", "bg-amber-500", "bg-blue-500", "bg-green-500"];
const TEXT = ["text-red-600", "text-amber-700", "text-blue-700", "text-green-700"];

/** The app's three-segment meter. Length-first: it explains, it does not scold. */
export function PasswordStrengthMeter({ id, password }: { id?: string; password: string }) {
  if (!password) {
    return (
      <p id={id} className="mt-1.5 text-xs text-gray-400">
        Use at least {PASSWORD_MIN_LENGTH} characters. Longer is stronger.
      </p>
    );
  }
  const score = passwordStrength(password);
  return (
    <div id={id} className="mt-2 flex items-center gap-3">
      <div className="flex flex-1 gap-1.5" aria-hidden>
        {[0, 1, 2].map((i) => (
          <span
            key={i}
            className={`h-1 flex-1 rounded-full transition-colors ${i < score ? BAR[score] : "bg-gray-200"}`}
          />
        ))}
      </div>
      <span className={`w-16 text-right text-xs font-semibold ${TEXT[score]}`} aria-live="polite">
        <span className="sr-only">Password strength: </span>
        {STRENGTH_LABELS[score]}
      </span>
    </div>
  );
}

export function PasswordChecklist({ id, items }: { id?: string; items: Requirement[] }) {
  return (
    <ul id={id} className="mt-2 space-y-1">
      {items.map((r) => (
        <li
          key={r.id}
          className={`flex items-center gap-2 text-xs ${r.met ? "text-green-700" : "text-gray-500"}`}
        >
          <span
            aria-hidden
            className={`inline-flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded-full text-[9px] font-bold ${
              r.met ? "bg-green-100 text-green-700" : "border border-gray-300"
            }`}
          >
            {r.met ? "✓" : ""}
          </span>
          {r.label}
          <span className="sr-only">{r.met ? " (done)" : " (not yet)"}</span>
        </li>
      ))}
    </ul>
  );
}
