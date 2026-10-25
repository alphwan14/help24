/**
 * Password recovery, done the provider's way.
 *
 * The reset email is Supabase's own (`resetPasswordForEmail`). Its link passes
 * through Supabase, which sends the browser on to RECOVERY_CALLBACK_PATH with a
 * one-time `code`; app/auth/callback trades that for a recovery session, and
 * /reset-password lets that session set a new password. There is no token or
 * expiry of Help24's own anywhere in it.
 *
 * WHY A LINK ONLY WORKS IN THE BROWSER THAT ASKED FOR IT
 * The browser client uses PKCE: requesting the email stores a verifier in this
 * browser's cookies, and the code cannot be exchanged without it. A link opened
 * on another device therefore cannot complete. The callback reports that case
 * separately, so the page can say what actually happened instead of calling a
 * perfectly fresh link "expired".
 *
 * THE OLD FLOW, FOR THE RECORD
 * The sign-in page used to send the link to `/login?message=password-updated`.
 * Nothing there exchanged the code or asked for a new password, so the person
 * was told "Password updated" while their password stayed exactly as it was.
 *
 * No imports, so `node --test` loads it directly (recovery-session.test.mjs).
 */

/**
 * Where Supabase sends a reset link. Supabase only honours a `redirectTo` on
 * its Site URL's host or in its Redirect URLs list; anything else silently
 * falls back to the Site URL — so this origin must be one of the two.
 */
export const RECOVERY_CALLBACK_PATH = "/auth/callback";

/** Where a recovery session goes to choose its new password. */
export const RESET_PASSWORD_PATH = "/reset-password";

/** The `redirectTo` for `resetPasswordForEmail`, on the origin the request came from. */
export function recoveryRedirectUrl(origin: string): string {
  return `${origin.replace(/\/+$/, "")}${RECOVERY_CALLBACK_PATH}`;
}

/** Why the callback could not create a recovery session. */
export type RecoveryLinkError = "link-invalid" | "other-browser";

export function parseRecoveryLinkError(value: string | null | undefined): RecoveryLinkError | null {
  return value === "link-invalid" || value === "other-browser" ? value : null;
}

/**
 * Sign-in methods the provider itself counts as recovery — GoTrue's
 * `AuthenticationMethod.IsRecovery()` is true for exactly these three. A
 * PKCE reset link yields `recovery`; the `token_hash` variant yields `otp`.
 */
const RECOVERY_METHODS = new Set(["recovery", "otp", "magiclink"]);

/**
 * How long after following the link the reset form stays open: the lifetime
 * Supabase gives the email link itself by default. A recovery session can
 * outlive this — it is an ordinary session afterwards — but the no-current-
 * password form should not.
 */
export const RECOVERY_WINDOW_SECONDS = 60 * 60;

/**
 * `recovery` — arrived from a reset link within the window: may set a password.
 * `signed-in` — an ordinary session: change the password from Settings instead.
 * `none` — no session: the link was invalid, expired, or opened elsewhere.
 */
export type RecoveryState = "recovery" | "signed-in" | "none";

/**
 * Classify verified JWT claims (`auth.getClaims()`) by their `amr` entries.
 *
 * This decides which screen to show, nothing more. The provider is still the
 * authority on whether a session may set a password without the old one.
 */
export function classifyRecoverySession(claims: unknown, nowSeconds: number): RecoveryState {
  if (!claims || typeof claims !== "object") return "none";
  const amr = (claims as { amr?: unknown }).amr;
  if (Array.isArray(amr)) {
    for (const entry of amr) {
      if (!entry || typeof entry !== "object") continue;
      const { method, timestamp } = entry as { method?: unknown; timestamp?: unknown };
      if (
        typeof method === "string" &&
        RECOVERY_METHODS.has(method) &&
        typeof timestamp === "number" &&
        nowSeconds - timestamp <= RECOVERY_WINDOW_SECONDS
      ) {
        return "recovery";
      }
    }
  }
  return "signed-in";
}
