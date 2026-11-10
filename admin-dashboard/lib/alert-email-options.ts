/**
 * Email alerts for admins: the choices, as the Settings page shows them.
 * Mirrors backend/src/admin/alert-emails/alert-email-rules.ts. Safe in client
 * components.
 */

export type AlertEmailCategory = "financial" | "trust_safety" | "support" | "marketplace";
export type AlertEmailFrequency = "instant" | "daily" | "off";

export type AlertEmailSettings = {
  frequency: AlertEmailFrequency;
  categories: AlertEmailCategory[];
  /** Where the emails go: this admin's console address. */
  email: string;
  /** False until the server is set up for it (migration 141, email sending). */
  available: boolean;
};

export const FREQUENCIES: Array<{ value: AlertEmailFrequency; label: string; hint: string }> = [
  { value: "instant", label: "Right away", hint: "Within about five minutes of something new." },
  { value: "daily", label: "Morning summary", hint: "One email at 8:00 with everything still waiting." },
  { value: "off", label: "Off", hint: "No alert emails." },
];

export const CATEGORIES: Array<{ value: AlertEmailCategory; label: string; hint: string }> = [
  { value: "support", label: "Support Inbox", hint: "Email waiting for a reply" },
  { value: "financial", label: "Money", hint: "Payments, payouts and disputes" },
  { value: "trust_safety", label: "Trust & safety", hint: "Reports, verifications and admin logins" },
  { value: "marketplace", label: "Marketplace", hint: "Jobs, requests and promotions" },
];
