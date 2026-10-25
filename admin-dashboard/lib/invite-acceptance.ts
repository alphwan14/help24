/**
 * Accepting an admin invitation, from the submitted form to where the person
 * lands. The route handler (app/accept-invite/submit/route.ts) supplies the
 * effects; everything that decides anything is here, so it can be tested.
 *
 * ── The bug this replaced ───────────────────────────────────────────────────
 * Acceptance used to finish in the BROWSER: the action provisioned the account
 * and stored the arbitration cookie, then a `useEffect` in AcceptInviteForm
 * signed in with the password and pushed to /dashboard. It never ran. In a
 * Server Action, setting any cookie marks the path revalidated
 * (next/dist/server/web/spec-extension/adapters/request-cookies.js →
 * `workStore.pathWasRevalidated = true`), so the action's response re-rendered
 * /accept-invite. That render called `getInvite(token)`, which the backend now
 * answers 410 "already been completed" — so the page swapped the form for the
 * error card and the effect unmounted before it could sign anyone in. The
 * invitee saw "Invite already completed" with their account fully created.
 *
 * The cookie was only the trigger: the same page shows the same card on a
 * plain refresh. The fix is to finish the whole hand-off on the server and
 * leave with a redirect — no step depends on a component surviving a re-render.
 *
 * ── Why a plain POST, not a Server Action ───────────────────────────────────
 * The first version of the fix redirected from the Server Action. Next turns
 * that into a client-side navigation, and after it NO later Server Action was
 * ever sent: Sign out hung on its first call (seen in e2e/run.mjs, every run;
 * a full page load cleared it). So the form posts to a Route Handler that
 * answers 303, and every outcome is an ordinary page load — no client router
 * state survives the hand-off, and the form works without JavaScript.
 *
 * ── Who gets in ─────────────────────────────────────────────────────────────
 * Provisioning creates the Supabase credential and the arbitration record; it
 * does NOT link the credential to a Help24 identity. That link is a human step
 * (docs/runbooks/admin-onboarding-and-identity-linking.md §1), and the dashboard
 * gate requires it. So after signing in, the identity is checked exactly as
 * middleware will check it; an invitee who is not linked yet is signed back
 * out and told so, instead of meeting "Access denied".
 *
 * No imports, so `node --test` loads it directly (invite-acceptance.test.mjs).
 */

export type InviteForm = {
  token: string;
  name: string;
  password: string;
  confirm: string;
  /**
   * The invited address as the page showed it — empty unless the server's
   * signature over (token, address) checked out (lib/invite-email-binding.ts).
   * Used for ONE thing only: signing in with the password just typed when a
   * retry finds the invitation already completed. A sign-in proves the
   * password; it grants nothing the sign-in page would not.
   */
  claimedEmail: string;
};

export type ProvisionedAdmin = { email: string; arbitrationToken: string };

/** What the backend reported; the shape of lib/api.ts → ApiError. */
export type ProvisionFailure = { status?: number; message?: string };

export interface InviteEffects {
  /** POST /admin/accept-invite. Throws a ProvisionFailure-shaped error. */
  provision(input: { token: string; name: string; password: string }): Promise<ProvisionedAdmin>;
  /** Establish the dashboard session in this response. Null when refused. */
  signIn(email: string, password: string): Promise<{ userId: string } | null>;
  /** The middleware's own question: does this credential resolve to an admin? */
  isDashboardAdmin(userId: string): Promise<boolean>;
  signOut(): Promise<void>;
  storeArbitrationToken(token: string): Promise<void>;
}

/**
 * Why a submission went nowhere. A fixed vocabulary, because it travels back
 * to the form in a URL (`/accept-invite?token=…&error=<code>`): free text there
 * would let anyone put words on Help24's page.
 */
export const INVITE_ERRORS = {
  "missing-token": "Missing invite token.",
  name: "Enter your full name.",
  "password-short": "Password must be at least 8 characters.",
  "password-mismatch": "Passwords do not match.",
  "already-used": "This invitation has already been used. If you set your password with it, sign in instead.",
  invitation: "This invitation can no longer be used.",
  unavailable: "We couldn't reach the server, so nothing was changed. Please try again.",
  rejected: "We couldn't accept this invitation with those details. Check them and try again.",
  unexpected: "Unexpected error. Please try again.",
} as const;

export type InviteErrorCode = keyof typeof INVITE_ERRORS;

export function inviteErrorMessage(code: string | null | undefined): string | null {
  return code && Object.hasOwn(INVITE_ERRORS, code) ? INVITE_ERRORS[code as InviteErrorCode] : null;
}

export type InviteOutcome =
  /** Signed in as a linked admin: go to /dashboard. */
  | { kind: "dashboard" }
  /** Account ready, but not linked to an admin identity yet: signed out again. */
  | { kind: "pending-activation" }
  /** Account ready, but the session could not be made here: sign in by hand. */
  | { kind: "sign-in" }
  /** Nothing to hand off — back to the form, saying why. */
  | { kind: "error"; code: InviteErrorCode };

/** The checks the form has always made, before anything is sent. */
export function validateInviteForm(form: InviteForm): InviteErrorCode | null {
  if (!form.token.trim()) return "missing-token";
  if (form.name.trim().length < 2) return "name";
  if (form.password.length < 8) return "password-short";
  if (form.password !== form.confirm) return "password-mismatch";
  return null;
}

/** The backend's terminal state for a used invitation (admin-invites.service.ts → getInvite / acceptInvite). */
export function isCompletedInvite(err: ProvisionFailure | null | undefined): boolean {
  return err?.status === 410 && /already been completed|already been used/i.test(err.message ?? "");
}

function codeOf(err: unknown): InviteErrorCode {
  const status = (err as ProvisionFailure | null)?.status;
  if (typeof status !== "number") return "unexpected";
  if (status === 404 || status === 410) return "invitation"; // the page will show which, on reload
  if (status >= 500) return "unavailable";
  return "rejected";
}

async function quietly<T>(call: () => Promise<T>): Promise<T | null> {
  try {
    return await call();
  } catch {
    return null;
  }
}

async function handOff(effects: InviteEffects, userId: string, arbitrationToken: string | null): Promise<InviteOutcome> {
  if (await quietly(() => effects.isDashboardAdmin(userId))) {
    // Pre-connect arbitration so the dashboard opens connected. Without it the
    // shell restores from the session anyway, so a token is a nicety, not a need.
    if (arbitrationToken) await quietly(() => effects.storeArbitrationToken(arbitrationToken));
    return { kind: "dashboard" };
  }
  await quietly(() => effects.signOut());
  return { kind: "pending-activation" };
}

export async function acceptInvitation(form: InviteForm, effects: InviteEffects): Promise<InviteOutcome> {
  const invalid = validateInviteForm(form);
  if (invalid) return { kind: "error", code: invalid };

  let provisioned: ProvisionedAdmin;
  try {
    provisioned = await effects.provision({
      token: form.token.trim(),
      name: form.name.trim(),
      password: form.password,
    });
  } catch (err) {
    // A retry of an acceptance that already went through (double submit, a
    // lost response, a second tab). The backend will not run it twice; if the
    // password typed is the one that was set, finish the hand-off.
    if (isCompletedInvite(err as ProvisionFailure)) {
      if (form.claimedEmail.trim()) {
        const session = await quietly(() => effects.signIn(form.claimedEmail.trim(), form.password));
        if (session) return handOff(effects, session.userId, null);
      }
      return { kind: "error", code: "already-used" };
    }
    return { kind: "error", code: codeOf(err) };
  }

  // The address comes from the backend's answer, never from the form.
  const session = await quietly(() => effects.signIn(provisioned.email, form.password));
  if (!session) return { kind: "sign-in" };
  return handOff(effects, session.userId, provisioned.arbitrationToken);
}
