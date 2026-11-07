import { recoveryRedirectUrl } from "./recovery-session";

/**
 * Set by the sign-in page just before it hands the browser to Google, read
 * (and cleared) by app/auth/callback. It only matters when Google comes back
 * WITHOUT a session — the person cancelled, or has no dashboard login — so the
 * callback returns them to the sign-in page rather than the password-reset
 * page that shares the route. A session that does come back says for itself
 * how it signed in (its `amr`), so nothing is decided by this cookie alone.
 */
export const GOOGLE_FLOW_COOKIE = "h24_google_flow";
export const GOOGLE_FLOW_MAX_AGE = 10 * 60;

/** The `amr` method a Google (or any OAuth) sign-in carries. */
export const OAUTH_METHOD = "oauth";

/** True when verified claims (`auth.getClaims()`) come from an OAuth sign-in. */
export function isOAuthSession(claims: unknown): boolean {
  const amr = (claims as { amr?: unknown } | null)?.amr;
  return Array.isArray(amr) && amr.some((e) => (e as { method?: unknown } | null)?.method === OAUTH_METHOD);
}

/** Why Google sign-in returned to the sign-in page (`/login?error=…`). */
export type GoogleSignInError = "google-not-admin" | "google-failed";

/**
 * The callback's verdict when Google came back without a code. GoTrue says
 * `error_code=signup_disabled` when the Google address has no dashboard login
 * (public sign-ups are off); an `access_denied` with no code is the person
 * backing out at Google, which deserves no message at all.
 */
export function googleReturnError(params: URLSearchParams): GoogleSignInError | null {
  const code = params.get("error_code") ?? "";
  const description = params.get("error_description") ?? "";
  if (code === "signup_disabled" || /signups? not allowed/i.test(description)) return "google-not-admin";
  if (params.get("error") === "access_denied") return null;
  return "google-failed";
}

/** Where Google sends the browser back: the dashboard's one auth callback. */
export function googleRedirectUrl(origin: string): string {
  return recoveryRedirectUrl(origin);
}
