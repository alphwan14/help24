/**
 * An admin's own dashboard password: the rules it must meet, and the two ways
 * to change it — from Settings, knowing the current one, and from a reset link.
 *
 * ── Whose password this is ──────────────────────────────────────────────────
 * A dashboard login is a Supabase Auth credential. Invite acceptance creates it
 * with `auth.admin.createUser({ email, password })` (backend
 * admin-invites.service.ts → ensureAuthUser), and the arbitration bearer token
 * is minted FROM that session, never from a password. So the only correct way
 * to change it is the provider's own `updateUser`, which acts on the session it
 * runs under and on nothing else. No id or email typed into a form ever reaches
 * it: the account is whoever the verified session says it is.
 *
 * ── How the current password is proved ──────────────────────────────────────
 * By signing in with it, as the session's own email, on a throwaway client
 * (lib/supabase-browser.ts → createReauthClient). That is a real authentication
 * by the provider rather than a comparison we make, and it yields a session
 * seconds old — which is exactly what Supabase's "secure password change"
 * setting asks for (it demands reauthentication only from sessions older than
 * 24 hours). The update then runs under that fresh session and also sends
 * `current_password`, so "require current password" passes too if the project
 * ever turns it on. Neither setting is bypassed; both are satisfied.
 *
 * ── What happens to other sessions ──────────────────────────────────────────
 * The provider decides: a password update signs out every OTHER session of the
 * account and keeps the one it ran under (GoTrue `User.UpdatePassword` →
 * `LogoutAllExceptMe`). This browser then adopts that session, so the admin
 * stays signed in here and nowhere else. The browser's own session is only
 * replaced when the password actually changed — a failed attempt leaves it
 * exactly as it was.
 *
 * No imports, so `node --test` loads it directly (admin-password.test.mjs).
 */

/* ════════════════════════════════════════════════════════════════════════════
 * THE RULES
 * ════════════════════════════════════════════════════════════════════════════ */

/**
 * The backend's invite rule (admin-invites.service.ts) and the mobile app's
 * `AuthService.minPasswordLength` — one number across every Help24 surface.
 */
export const PASSWORD_MIN_LENGTH = 8;

/**
 * Supabase Auth hashes with bcrypt, which reads at most 72 BYTES, and refuses
 * anything longer outright. Checked here so the refusal arrives as a field
 * message instead of a provider error.
 */
export const PASSWORD_MAX_BYTES = 72;

/**
 * The rule-check — the mobile app's `AuthService.validatePassword`, plus the
 * provider's byte ceiling. Returns the problem, or null when there is none.
 */
export function passwordProblem(password: string): string | null {
  if (password.length === 0) return "Enter a password.";
  if (password.length < PASSWORD_MIN_LENGTH) {
    return `Use at least ${PASSWORD_MIN_LENGTH} characters.`;
  }
  if (/^\d+$/.test(password)) return "Add letters as well as numbers.";
  if (new TextEncoder().encode(password).length > PASSWORD_MAX_BYTES) {
    return "That password is too long. Use a shorter one.";
  }
  return null;
}

export type StrengthScore = 0 | 1 | 2 | 3;

/** Indexed by score. The app's labels, so a person sees the same words in both. */
export const STRENGTH_LABELS = ["Too weak", "Okay", "Good", "Strong"] as const;

/**
 * Rough strength in 0–3, the app's `AuthService.passwordStrength`. Length
 * dominates, because length is what resists guessing.
 *
 * The floor is the RULE-CHECK, not a length: a meter that calls `12345678`
 * "Okay" while the form refuses it is the product contradicting itself, which
 * is the bug the app already fixed once.
 */
export function passwordStrength(password: string): StrengthScore {
  if (passwordProblem(password) !== null) return 0;
  let score = 1;
  if (password.length >= 12) score++;
  const classes = [/[a-z]/, /[A-Z]/, /\d/, /[^\w\s]/].filter((r) => r.test(password)).length;
  if (classes >= 3) score++;
  return Math.min(score, 3) as StrengthScore;
}

export type Requirement = { id: string; label: string; met: boolean };

/**
 * The live checklist under the new-password field. Pass `currentPassword` only
 * on the change form; a reset link has no current password to compare with.
 */
export function passwordRequirements(newPassword: string, currentPassword?: string): Requirement[] {
  const items: Requirement[] = [
    {
      id: "length",
      label: `At least ${PASSWORD_MIN_LENGTH} characters`,
      met: newPassword.length >= PASSWORD_MIN_LENGTH,
    },
    {
      id: "letters",
      label: "Not only numbers",
      met: newPassword.length > 0 && !/^\d+$/.test(newPassword),
    },
  ];
  if (currentPassword !== undefined) {
    items.push({
      id: "different",
      label: "Different from your current password",
      met: newPassword.length > 0 && newPassword !== currentPassword,
    });
  }
  return items;
}

export type PasswordField = "currentPassword" | "newPassword" | "confirmPassword";
export type FieldErrors = Partial<Record<PasswordField, string>>;

export type PasswordChangeInput = {
  currentPassword: string;
  newPassword: string;
  confirmPassword: string;
};

export type PasswordResetInput = {
  newPassword: string;
  confirmPassword: string;
};

/** Field order on screen, so the first error to focus is the topmost one. */
export const FIELD_ORDER: PasswordField[] = ["currentPassword", "newPassword", "confirmPassword"];

export function hasErrors(errors: FieldErrors): boolean {
  return FIELD_ORDER.some((f) => errors[f]);
}

function validateNewAndConfirm(
  input: PasswordResetInput,
  currentPassword?: string,
): FieldErrors {
  const errors: FieldErrors = {};
  if (!input.newPassword) {
    errors.newPassword = "Enter a new password.";
  } else {
    const problem = passwordProblem(input.newPassword);
    if (problem) errors.newPassword = problem;
    else if (currentPassword && input.newPassword === currentPassword) {
      errors.newPassword = "Your new password must be different from your current one.";
    }
  }
  if (!input.confirmPassword) {
    errors.confirmPassword = "Re-enter your new password.";
  } else if (input.confirmPassword !== input.newPassword) {
    errors.confirmPassword = "The passwords don't match.";
  }
  return errors;
}

/** Everything the change form can know before asking the provider. */
export function validatePasswordChange(input: PasswordChangeInput): FieldErrors {
  const errors = validateNewAndConfirm(input, input.currentPassword);
  if (!input.currentPassword) errors.currentPassword = "Enter your current password.";
  return errors;
}

/** Everything the reset form can know before asking the provider. */
export function validatePasswordReset(input: PasswordResetInput): FieldErrors {
  return validateNewAndConfirm(input);
}

/* ════════════════════════════════════════════════════════════════════════════
 * THE PROVIDER, AS FAR AS THIS MODULE NEEDS IT
 *
 * Structural slices of supabase-js's `auth` client, so production passes
 * `supabase.auth` and the tests pass a double — or a real client pointed at a
 * GoTrue-protocol fake (admin-password.gotrue.test.mjs).
 * ════════════════════════════════════════════════════════════════════════════ */

/** The fields of supabase-js's AuthError that the mapping below reads. */
export type AuthErrorLike = {
  name?: string;
  message?: string;
  status?: number;
  code?: string;
  /** Only on AuthWeakPasswordError: "length" | "characters" | "pwned". */
  reasons?: string[];
};

export type AuthUserLike = {
  id: string;
  email?: string | null;
  identities?: { provider: string }[] | null;
};

export type AuthSessionLike = { access_token: string; refresh_token: string };

type Result<T> = { data: T; error: AuthErrorLike | null };

/** The browser's own client — the session this page is signed in with. */
export interface SessionAuth {
  getUser(): Promise<Result<{ user: AuthUserLike | null }>>;
  setSession(session: AuthSessionLike): Promise<{ error: AuthErrorLike | null }>;
}

/** A throwaway client, used to prove the current password and run the update. */
export interface VerifierAuth {
  signInWithPassword(credentials: { email: string; password: string }): Promise<
    Result<{ user: AuthUserLike | null; session: AuthSessionLike | null }>
  >;
  updateUser(attributes: { password: string; current_password?: string }): Promise<
    Result<{ user: AuthUserLike | null }>
  >;
  signOut(options?: { scope?: "global" | "local" | "others" }): Promise<{ error: AuthErrorLike | null }>;
}

/** The browser's own client while it holds a recovery session from a reset link. */
export interface RecoveryAuth {
  getUser(): Promise<Result<{ user: AuthUserLike | null }>>;
  updateUser(attributes: { password: string }): Promise<Result<{ user: AuthUserLike | null }>>;
}

export interface ResetRequestAuth {
  resetPasswordForEmail(
    email: string,
    options?: { redirectTo?: string },
  ): Promise<{ error: AuthErrorLike | null }>;
}

/**
 * Whether this account signs in with a password at all.
 *
 * Supabase records an `email` identity for email/password accounts — the only
 * kind the dashboard signs in with. An account with identities but none of
 * them `email` (a social-only login, say) has no password to change, and the
 * form would only ever tell it "wrong password". When the response carries no
 * identities, assume a password and let the provider be the judge.
 */
export function hasPasswordSignIn(user: AuthUserLike): boolean {
  if (!user.email) return false;
  if (!user.identities || user.identities.length === 0) return true;
  return user.identities.some((i) => i.provider === "email");
}

/* ════════════════════════════════════════════════════════════════════════════
 * OUTCOMES
 * ════════════════════════════════════════════════════════════════════════════ */

export type FailureReason =
  | "invalid"
  | "wrong_current_password"
  | "session_expired"
  | "no_password"
  | "account_disabled"
  | "rate_limited"
  | "reauth_required"
  | "identity_mismatch"
  | "network"
  | "unknown_outcome"
  | "provider";

export type PasswordOutcome =
  /** `sessionKept` is false only when the password changed but this browser could not adopt the session it changed under. */
  | { ok: true; sessionKept: boolean }
  | { ok: false; reason: FailureReason; fieldErrors?: FieldErrors; message?: string };

/**
 * What a person reads. Every failure VALUE ends up as one of these — a raw
 * provider message never reaches the screen.
 */
export const FAILURE_MESSAGES: Record<Exclude<FailureReason, "invalid" | "wrong_current_password">, string> = {
  session_expired: "Your session has expired. Sign in again, then change your password.",
  no_password:
    "This account doesn't sign in with a password, so there isn't one to change here.",
  account_disabled: "This account has been disabled. Contact a super admin.",
  rate_limited: "Too many attempts. Wait a few minutes, then try again.",
  reauth_required: "For your security, sign in again before changing your password.",
  identity_mismatch:
    "We couldn't confirm which account this is, so nothing was changed. Sign out, sign in again, and retry.",
  network:
    "We couldn't reach the sign-in service, so nothing was changed. Check your connection and try again.",
  unknown_outcome:
    "The connection dropped before the change was confirmed, so we can't tell whether it went through. Next time you sign in, try your new password first — if it doesn't work, your old one still does.",
  provider: "We couldn't change your password, and nothing was changed. Please try again.",
};

const WRONG_CURRENT = "That isn't your current password.";

function failure(reason: Exclude<FailureReason, "invalid" | "wrong_current_password">): PasswordOutcome {
  return { ok: false, reason, message: FAILURE_MESSAGES[reason] };
}

function onField(reason: FailureReason, fieldErrors: FieldErrors): PasswordOutcome {
  return { ok: false, reason, fieldErrors };
}

/* ── Reading a provider error ─────────────────────────────────────────────── */

/** A request that never got a definite answer: offline, DNS, or a 502/503/504. */
function isTransport(error: AuthErrorLike): boolean {
  return error.name === "AuthRetryableFetchError";
}

/**
 * supabase-js turns GoTrue's `session_not_found` into AuthSessionMissingError
 * and drops the code, so the name is folded back into one.
 */
function codeOf(error: AuthErrorLike): string {
  if (error.name === "AuthSessionMissingError") return "session_not_found";
  return error.code ?? "";
}

function weakPasswordMessage(reasons: string[] | undefined): string {
  const r = reasons ?? [];
  if (r.includes("pwned")) {
    return "This password has appeared in a known data breach. Choose a different one.";
  }
  if (r.includes("characters")) {
    return "Help24's sign-in rules need more variety. Mix upper- and lower-case letters, numbers and symbols.";
  }
  if (r.includes("length")) return "That password is too short for Help24's sign-in rules.";
  return "That password isn't strong enough. Try a longer one.";
}

/**
 * Signing in with the claimed current password failed. Nothing has changed at
 * this point, whatever the error.
 */
function verifyFailure(error: AuthErrorLike | null): PasswordOutcome {
  if (!error) return failure("provider");
  if (isTransport(error)) return failure("network");
  const code = codeOf(error);
  if (code === "invalid_credentials" || /invalid login credentials/i.test(error.message ?? "")) {
    return onField("wrong_current_password", { currentPassword: WRONG_CURRENT });
  }
  if (code === "user_banned") return failure("account_disabled");
  if (code === "over_request_rate_limit" || error.status === 429) return failure("rate_limited");
  return failure("provider");
}

/**
 * The update itself failed. A definite refusal (4xx) changed nothing; a
 * transport failure or a 5xx might have landed after the change committed, so
 * those are reported as unknown rather than as "nothing changed".
 */
function updateFailure(error: AuthErrorLike): PasswordOutcome {
  if (isTransport(error) || error.name === "AuthUnknownError" || (error.status ?? 0) >= 500) {
    return failure("unknown_outcome");
  }
  switch (codeOf(error)) {
    case "same_password":
      return onField("invalid", {
        newPassword: "Your new password must be different from your current one.",
      });
    case "weak_password":
      return onField("invalid", { newPassword: weakPasswordMessage(error.reasons) });
    case "validation_failed":
      return onField("invalid", { newPassword: "That password can't be used. Choose a different one." });
    case "current_password_mismatch":
    case "current_password_required":
      return onField("wrong_current_password", { currentPassword: WRONG_CURRENT });
    case "reauthentication_needed":
    case "reauthentication_not_valid":
    case "insufficient_aal":
      return failure("reauth_required");
    case "session_not_found":
    case "session_expired":
    case "bad_jwt":
    case "no_authorization":
      return failure("session_expired");
    case "user_banned":
      return failure("account_disabled");
    case "over_request_rate_limit":
      return failure("rate_limited");
  }
  if (error.status === 401) return failure("session_expired");
  if (error.status === 429) return failure("rate_limited");
  return failure("provider");
}

/** Errors from supabase-js arrive as values; anything THROWN is a transport failure. */
async function attempt<T>(call: () => Promise<T>): Promise<T | { thrown: true }> {
  try {
    return await call();
  } catch {
    return { thrown: true };
  }
}

function threw(r: unknown): r is { thrown: true } {
  return typeof r === "object" && r !== null && "thrown" in r;
}

const THROWN: AuthErrorLike = { name: "AuthRetryableFetchError", status: 0 };

/** Who the verified session belongs to — the provider's answer, not the cookie's. */
async function sessionUser(auth: { getUser: SessionAuth["getUser"] }): Promise<AuthUserLike | null> {
  const r = await attempt(() => auth.getUser());
  if (threw(r) || r.error || !r.data?.user) return null;
  return r.data.user;
}

/* ════════════════════════════════════════════════════════════════════════════
 * THE FLOWS
 * ════════════════════════════════════════════════════════════════════════════ */

/**
 * Change the signed-in admin's password, from Settings.
 *
 * `session` is this browser's client; `createVerifier` makes a throwaway one.
 * The order is the security argument, so it is spelled out:
 *
 *   1. our rules — nothing invalid is ever sent;
 *   2. WHO, from the provider's verification of this browser's session;
 *   3. the current password proved by signing in as that same account,
 *      on the throwaway client, and the account it answers for re-checked;
 *   4. the update, under that minutes-old session;
 *   5. this browser adopts that session — the provider has just signed out
 *      every other one, including the one this page was using.
 */
export async function changeOwnPassword(
  session: SessionAuth,
  createVerifier: () => VerifierAuth,
  input: PasswordChangeInput,
): Promise<PasswordOutcome> {
  const invalid = validatePasswordChange(input);
  if (hasErrors(invalid)) return onField("invalid", invalid);

  const user = await sessionUser(session);
  if (!user) return failure("session_expired");
  if (!hasPasswordSignIn(user)) return failure("no_password");

  const verifier = createVerifier();
  const signIn = await attempt(() =>
    verifier.signInWithPassword({ email: user.email as string, password: input.currentPassword }),
  );
  if (threw(signIn)) return failure("network");
  const fresh = signIn.data?.session;
  if (signIn.error || !fresh || !signIn.data?.user) return verifyFailure(signIn.error);

  // Cannot happen while emails are unique in auth.users — and if it ever did,
  // the update must not run as somebody else.
  if (signIn.data.user.id !== user.id) {
    await attempt(() => verifier.signOut({ scope: "local" }));
    return failure("identity_mismatch");
  }

  const update = await attempt(() =>
    verifier.updateUser({ password: input.newPassword, current_password: input.currentPassword }),
  );
  const updateError = threw(update) ? THROWN : update.error;

  if (updateError) {
    const outcome = updateFailure(updateError);
    if (outcome.ok === false && outcome.reason === "unknown_outcome") {
      // It may have landed, in which case the only live session left is the
      // fresh one; adopting it keeps this browser signed in either way.
      await attempt(() => session.setSession(fresh));
    } else {
      // A definite refusal: nothing changed, so retire the extra session and
      // leave this browser's own session exactly as it was.
      await attempt(() => verifier.signOut({ scope: "local" }));
    }
    return outcome;
  }

  const adopted = await attempt(() => session.setSession(fresh));
  return { ok: true, sessionKept: !threw(adopted) && !adopted.error };
}

/**
 * Set a new password from a reset link. The browser's own client holds the
 * recovery session the link created, and the provider accepts a new password
 * from it without the old one — that is what a recovery session is for.
 */
export async function resetOwnPassword(
  auth: RecoveryAuth,
  input: PasswordResetInput,
): Promise<PasswordOutcome> {
  const invalid = validatePasswordReset(input);
  if (hasErrors(invalid)) return onField("invalid", invalid);

  const user = await sessionUser(auth);
  if (!user) return failure("session_expired");

  const update = await attempt(() => auth.updateUser({ password: input.newPassword }));
  const updateError = threw(update) ? THROWN : update.error;
  if (updateError) return updateFailure(updateError);
  return { ok: true, sessionKept: true };
}

/**
 * Ask the provider to email a reset link. Its `/recover` answers the same
 * whether or not the address has an account, and so does this.
 */
export async function requestPasswordReset(
  auth: ResetRequestAuth,
  email: string,
  redirectTo: string,
): Promise<{ ok: true } | { ok: false; message: string }> {
  const address = email.trim();
  if (!address) return { ok: false, message: "Enter your email address to reset your password." };

  const r = await attempt(() => auth.resetPasswordForEmail(address, { redirectTo }));
  const error = threw(r) ? THROWN : r.error;
  if (!error) return { ok: true };
  if (isTransport(error)) {
    return { ok: false, message: "We couldn't reach the sign-in service. Check your connection and try again." };
  }
  if (
    error.code === "over_email_send_rate_limit" ||
    error.code === "over_request_rate_limit" ||
    error.status === 429
  ) {
    return {
      ok: false,
      message: "Too many reset emails have been requested. Wait a while, then try again.",
    };
  }
  return { ok: false, message: "We couldn't send the reset email. Try again later." };
}
