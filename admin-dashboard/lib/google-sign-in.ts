/**
 * "Continue with Google" on the admin sign-in page — Google Identity Services.
 *
 * Google's own button signs the person in on admin.help24.co.ke and hands the
 * page a signed ID token; the page gives it to Supabase (`signInWithIdToken`).
 * The browser never visits the provider's address, so Google's account screen
 * names admin.help24.co.ke — and, once Google has verified the Help24
 * branding, "Help24" — rather than the Supabase project host that the
 * redirect flow showed. Then app/api/admin/google-check asks the admin gate
 * before the dashboard opens; a Google account that is not a linked admin is
 * signed straight back out.
 */

/**
 * The "Help24 admin" web client in the Help24 Google Cloud project. A client
 * id is public by design (Google puts it in every sign-in page); its
 * Authorised JavaScript origins — https://admin.help24.co.ke only — are what
 * stop another site from using it. Supabase must list it under the Google
 * provider's Client IDs, or it refuses the token's audience.
 */
export const GOOGLE_CLIENT_ID =
  process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID ?? "454215745233-dmb397i77e4nomh880srfjfirimbfpjg.apps.googleusercontent.com";

/** Google's script; the e2e run points this at its stand-in. */
export const GOOGLE_GSI_SRC = process.env.NEXT_PUBLIC_GOOGLE_GSI_SRC ?? "https://accounts.google.com/gsi/client";

/**
 * A fresh nonce per button: Google puts its SHA-256 (hex) in the ID token,
 * Supabase is given the raw value and checks the two agree — so a token
 * lifted from elsewhere cannot be replayed here.
 */
export async function makeNonce(): Promise<{ raw: string; hashed: string }> {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const raw = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw));
  const hashed = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
  return { raw, hashed };
}

/** Why Google sign-in left the person on the sign-in page (keys of the page's messages). */
export type GoogleSignInError = "google-not-admin" | "google-failed" | "not-linked" | "unavailable";

/**
 * Supabase refuses a Google address that has no dashboard login with
 * `signup_disabled`, because public sign-ups are off. That person proved they
 * own the Google account, so saying "not an admin login" reveals nothing about
 * anyone else.
 */
export function idTokenError(error: { code?: string; message?: string }): GoogleSignInError {
  if (error.code === "signup_disabled" || /signups? not allowed/i.test(error.message ?? "")) return "google-not-admin";
  return "google-failed";
}
