// Words for the security log (Users > Security log, migration 146).
//
// Pure: no server or client imports, so node --test can check it directly.
// Everything a super admin reads in the log is said here once.

export type Who = "admin" | "member" | "partner" | "other";
export type Category = "sign_in" | "admin_action" | "account";

export const WHO_FILTERS: Array<{ id: "all" | Exclude<Who, "other">; label: string }> = [
  { id: "all", label: "Everyone" },
  { id: "admin", label: "Admins" },
  { id: "member", label: "Members" },
  { id: "partner", label: "Partners" },
];

export const CATEGORY_FILTERS: Array<{ id: "all" | Category | "failed"; label: string }> = [
  { id: "all", label: "All activity" },
  { id: "sign_in", label: "Sign-ins" },
  { id: "failed", label: "Failed attempts" },
  { id: "admin_action", label: "Admin actions" },
  { id: "account", label: "Account changes" },
];

export function whoFilter(v: string | undefined): "all" | Exclude<Who, "other"> {
  return v === "admin" || v === "member" || v === "partner" ? v : "all";
}

export function categoryFilter(v: string | undefined): "all" | Category | "failed" {
  return v === "sign_in" || v === "admin_action" || v === "account" || v === "failed" ? v : "all";
}

/** A person filter from the URL: "admin:<uuid>" or "member:<id>". */
export function personFilter(v: string | undefined): { kind: "admin" | "member"; id: string } | null {
  const m = /^(admin|member):([A-Za-z0-9_-]{1,128})$/.exec(v ?? "");
  if (!m) return null;
  if (m[1] === "admin" && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(m[2])) return null;
  return { kind: m[1] as "admin" | "member", id: m[2] };
}

// ── Events this log records itself (public.security_events) ─────────────────

export const EVENT_LABELS: Record<string, string> = {
  "console.opened": "Opened the console",
  "console.refused": "Was refused console access",
  "sign_in.failed": "Failed to sign in",
  "google.refused": "Google sign-in was refused",
  "member.signed_in": "Signed in to the app",
};

export function eventLabel(event: string): string {
  return EVENT_LABELS[event] ?? humanize(event.replace(".", " "));
}

export function eventCategory(event: string): Category {
  return event.startsWith("member.") || event.startsWith("console.") || event.startsWith("sign_in.") || event.startsWith("google.")
    ? "sign_in"
    : "account";
}

/** How a member signed in, from Firebase's sign_in_provider. */
export function memberMethod(provider: string | null | undefined): string | null {
  switch (provider) {
    case "phone":
      return "with phone number";
    case "google.com":
      return "with Google";
    case "password":
      return "with email";
    case "apple.com":
      return "with Apple";
    case "custom":
    case "anonymous":
    case "":
    case null:
    case undefined:
      return null;
    default:
      return `with ${provider}`;
  }
}

/** Why the console refused someone, from the backend's status or the gate's reason. */
export function refusalReason(reason: string | null | undefined): string | null {
  switch (reason) {
    case "401":
      return "Session could not be verified";
    case "403":
      return "Not an active admin";
    case "404":
      return "No admin record for this login";
    case "unlinked":
      return "Login not linked to a Help24 person";
    case "not_admin":
      return "Not an admin";
    case "unavailable":
      return "Admin check was unavailable";
    case "invalid_credentials":
      return "Wrong email or password";
    case "email_not_confirmed":
      return "Email not confirmed";
    case "rate_limited":
      return "Too many attempts";
    case null:
    case undefined:
    case "":
      return null;
    default:
      return humanize(reason);
  }
}

// ── Supabase Auth's own audit log (admin and partner logins) ────────────────

const AUTH_ACTIONS: Record<string, { label: string; category: Category }> = {
  login: { label: "Signed in", category: "sign_in" },
  logout: { label: "Signed out", category: "sign_in" },
  user_signedup: { label: "Created a login", category: "account" },
  user_invited: { label: "Was invited", category: "account" },
  invite_accepted: { label: "Accepted an invite", category: "account" },
  user_confirmation_requested: { label: "Asked for a confirmation email", category: "account" },
  user_recovery_requested: { label: "Asked for a password reset", category: "account" },
  user_reauthenticate_requested: { label: "Asked to confirm it is them", category: "account" },
  user_updated_password: { label: "Changed their password", category: "account" },
  user_modified: { label: "Updated their login", category: "account" },
  user_deleted: { label: "Login deleted", category: "account" },
  user_repeated_signup: { label: "Tried to sign up again", category: "account" },
  identity_linked: { label: "Linked a sign-in method", category: "account" },
  identity_unlinked: { label: "Removed a sign-in method", category: "account" },
  factor_in_progress: { label: "Started setting up two-step sign-in", category: "account" },
  factor_unenrolled: { label: "Removed two-step sign-in", category: "account" },
  challenge_created: { label: "Was asked for a two-step code", category: "sign_in" },
  verification_attempted: { label: "Entered a two-step code", category: "sign_in" },
  factor_deleted: { label: "Removed two-step sign-in", category: "account" },
};

export function authAction(action: string | null | undefined): { label: string; category: Category } {
  return AUTH_ACTIONS[action ?? ""] ?? { label: humanize(action ?? "Account event"), category: "account" };
}

export function authMethod(provider: string | null | undefined): string | null {
  if (provider === "email") return "with password";
  if (provider === "google") return "with Google";
  if (!provider) return null;
  return `with ${provider}`;
}

// ── Admin actions recorded elsewhere ─────────────────────────────────────────

export const FINANCE_ACTIONS: Record<string, string> = {
  manual_settlement_recorded: "Recorded a manual settlement",
  ruling_applied: "Applied a dispute ruling",
};

export const PARTNER_ACTIONS: Record<string, string> = {
  created: "Added a partner agent",
  suspended: "Suspended a partner agent",
  reactivated: "Reactivated a partner agent",
  invite_issued: "Sent a partner invite",
  login_linked: "Linked a partner login",
};

const KIND_WORD: Record<string, string> = { request: "request", offer: "offer", job: "job" };

export function typeChangeLabel(from: string, to: string): string {
  return `Changed a listing from ${KIND_WORD[from] ?? from} to ${KIND_WORD[to] ?? to}`;
}

export function controlChangeLabel(key: string): string {
  return `Changed the app control "${humanize(key)}"`;
}

// ── Where and on what ────────────────────────────────────────────────────────

/**
 * A short device name from a user agent: "Chrome on Android", "Safari on
 * iPhone", "Help24 app". Unknown agents say "Unknown device" rather than the
 * raw string, which is kept for the details view.
 */
export function describeDevice(ua: string | null | undefined): string | null {
  if (!ua) return null;
  if (/^Dart\//.test(ua) || /dart:io/.test(ua)) return "Help24 app";
  const os = /iPhone/.test(ua)
    ? "iPhone"
    : /iPad/.test(ua)
      ? "iPad"
      : /Android/.test(ua)
        ? "Android"
        : /Windows/.test(ua)
          ? "Windows"
          : /Mac OS X|Macintosh/.test(ua)
            ? "Mac"
            : /CrOS/.test(ua)
              ? "ChromeOS"
              : /Linux/.test(ua)
                ? "Linux"
                : null;
  const browser = /EdgA?\//.test(ua)
    ? "Edge"
    : /OPR\/|Opera/.test(ua)
      ? "Opera"
      : /SamsungBrowser\//.test(ua)
        ? "Samsung Internet"
        : /Firefox\/|FxiOS\//.test(ua)
          ? "Firefox"
          : /Chrome\/|CriOS\//.test(ua)
            ? "Chrome"
            : /Safari\//.test(ua)
              ? "Safari"
              : null;
  if (browser && os) return `${browser} on ${os}`;
  return browser ?? os ?? "Unknown device";
}

const REGION = (() => {
  try {
    return new Intl.DisplayNames(["en"], { type: "region" });
  } catch {
    return null;
  }
})();

/** "Nairobi, Kenya" from the host's geo headers; either part may be missing. */
export function describePlace(country: string | null | undefined, city: string | null | undefined): string | null {
  let countryName: string | null = null;
  if (country && /^[A-Z]{2}$/i.test(country)) {
    try {
      countryName = REGION?.of(country.toUpperCase()) ?? country.toUpperCase();
    } catch {
      countryName = country.toUpperCase();
    }
  } else if (country) {
    countryName = country;
  }
  const parts = [city?.trim() || null, countryName].filter(Boolean);
  return parts.length ? parts.join(", ") : null;
}

export function humanize(s: string): string {
  const t = s.replace(/[_.]+/g, " ").trim();
  return t ? t[0].toUpperCase() + t.slice(1) : t;
}
