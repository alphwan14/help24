import { createHmac, timingSafeEqual } from "node:crypto";

/**
 * Ties the address shown on an invitation page to that invitation.
 *
 * When a retried acceptance finds the invitation already completed, the action
 * signs in with the page's address and the password just typed
 * (lib/invite-acceptance.ts). The backend no longer says whose invitation it
 * was, so the address travels in the form — and a form field is the client's
 * to change. Signing it here, when the server renders the page from the
 * backend's own answer, means the action only ever tries the address that
 * invitation was for. A sign-in proves the password either way; this keeps the
 * retry from becoming a way to try passwords against any other account.
 *
 * Keyed from SUPABASE_SERVICE_ROLE_KEY, which never leaves the server. Without
 * it nothing is signed and every check fails, so the retry falls back to the
 * honest "already used" message. Server code only.
 */

const PURPOSE = "help24:invite-email-binding:v1";

function key(): Buffer | null {
  const secret = process.env.SUPABASE_SERVICE_ROLE_KEY;
  return secret ? createHmac("sha256", secret).update(PURPOSE).digest() : null;
}

function mac(k: Buffer, token: string, email: string): string {
  return createHmac("sha256", k).update(`${token}\n${email.trim().toLowerCase()}`).digest("base64url");
}

export function signInvitedEmail(token: string, email: string): string | null {
  const k = key();
  return k ? mac(k, token, email) : null;
}

export function isInvitedEmail(token: string, email: string, signature: string): boolean {
  const k = key();
  if (!k || !token || !email || !signature) return false;
  const expected = Buffer.from(mac(k, token, email));
  const given = Buffer.from(signature);
  return expected.length === given.length && timingSafeEqual(expected, given);
}
