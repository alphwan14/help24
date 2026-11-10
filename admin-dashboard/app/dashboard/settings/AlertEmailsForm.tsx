"use client";

import { useState, useTransition } from "react";
import {
  CATEGORIES,
  FREQUENCIES,
  type AlertEmailCategory,
  type AlertEmailFrequency,
  type AlertEmailSettings,
} from "@/lib/alert-email-options";
import { saveAlertEmailSettings, sendTestAlertEmail } from "@/lib/alert-email-actions";

/**
 * The admin's own alert emails: how often, and about what. Saved on the
 * server; the emails name only what kind of thing is waiting, never details.
 */
export default function AlertEmailsForm({ initial }: { initial: AlertEmailSettings }) {
  const [frequency, setFrequency] = useState<AlertEmailFrequency>(initial.frequency);
  const [categories, setCategories] = useState<AlertEmailCategory[]>(initial.categories);
  const [saved, setSaved] = useState({ frequency: initial.frequency, categories: initial.categories });
  const [pending, startTransition] = useTransition();
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);

  const off = frequency === "off";
  const dirty =
    frequency !== saved.frequency ||
    categories.length !== saved.categories.length ||
    categories.some((c) => !saved.categories.includes(c));

  const toggle = (c: AlertEmailCategory) =>
    setCategories((now) => (now.includes(c) ? now.filter((x) => x !== c) : [...now, c]));

  const save = () => {
    setMessage(null);
    startTransition(async () => {
      const r = await saveAlertEmailSettings(frequency, categories);
      if (!r.ok || !r.settings) {
        setMessage({ ok: false, text: r.error ?? "Could not save. Please try again." });
        return;
      }
      setSaved({ frequency: r.settings.frequency, categories: r.settings.categories });
      setMessage({ ok: true, text: "Saved." });
    });
  };

  const test = () => {
    setMessage(null);
    startTransition(async () => {
      const r = await sendTestAlertEmail();
      setMessage(
        r.ok
          ? { ok: true, text: `Test email sent to ${r.sentTo}. If it isn't there in a minute, check spam.` }
          : { ok: false, text: r.error ?? "The test email could not be sent." },
      );
    });
  };

  return (
    <div className="mt-4 space-y-5" data-testid="alert-emails">
      <fieldset>
        <legend className="text-sm font-medium text-gray-900">How often</legend>
        <div className="mt-2 space-y-2">
          {FREQUENCIES.map((f) => (
            <label key={f.value} className="flex cursor-pointer items-start gap-3 text-sm">
              <input
                type="radio"
                name="alert-frequency"
                value={f.value}
                checked={frequency === f.value}
                onChange={() => setFrequency(f.value)}
                className="mt-1 accent-gray-900"
              />
              <span>
                <span className="font-medium text-gray-900">{f.label}</span>
                <span className="block text-[13px] text-gray-500">{f.hint}</span>
              </span>
            </label>
          ))}
        </div>
      </fieldset>

      <fieldset disabled={off} className={off ? "opacity-50" : ""}>
        <legend className="text-sm font-medium text-gray-900">About</legend>
        <div className="mt-2 grid gap-2 sm:grid-cols-2">
          {CATEGORIES.map((c) => (
            <label key={c.value} className="flex cursor-pointer items-start gap-3 text-sm">
              <input
                type="checkbox"
                name="alert-category"
                value={c.value}
                checked={categories.includes(c.value)}
                onChange={() => toggle(c.value)}
                className="mt-1 accent-gray-900"
              />
              <span>
                <span className="font-medium text-gray-900">{c.label}</span>
                <span className="block text-[13px] text-gray-500">{c.hint}</span>
              </span>
            </label>
          ))}
        </div>
      </fieldset>

      <div className="flex flex-wrap items-center gap-3">
        <button type="button" className="btn-primary" disabled={pending || !dirty} onClick={save}>
          {pending ? "Saving…" : "Save"}
        </button>
        <button type="button" className="btn-ghost" disabled={pending} onClick={test}>
          Send me a test
        </button>
        {message && (
          <p role={message.ok ? "status" : "alert"} className={`text-[13px] ${message.ok ? "text-gray-600" : "text-critical-700"}`}>
            {message.text}
          </p>
        )}
      </div>
    </div>
  );
}
