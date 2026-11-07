"use server";

import { passwordProblem } from "@/lib/admin-password";
import { resolvePartnerAccess } from "@/lib/partners/access";
import { hashInviteToken } from "@/lib/partners/rules";
import { headers } from "next/headers";
import { createServiceClient, createSessionWriter } from "@/lib/supabase-server";
import { plausibleEmail, sendResetUniformly, tooManyResetRequests } from "@/lib/password-reset";
import { recoveryRedirectUrl } from "@/lib/recovery-session";

/**
 * `done` means "signed in — navigate to /". The actions never redirect
 * themselves: a server action renders its redirect target in the same request,
 * WITHOUT middleware, so on the partner host "/" would resolve to the admin
 * app's root instead of the portal (seen in e2e as a 404). The form navigates
 * instead, through middleware like any other page load.
 */
export type FormState = { error?: string; email?: string; done?: boolean };

const DENIAL_WORDS: Record<string, string> = {
  not_partner: "This sign-in isn't a Help24 partner account.",
  suspended: "This partner account is paused. Contact Help24 if you think that's a mistake.",
  unavailable: "We couldn't check your account just now. Please try again.",
};

/** Partner sign-in: email and password, then the partner check. */
export async function signInPartner(_prev: FormState, form: FormData): Promise<FormState> {
  const email = String(form.get("email") ?? "").trim().toLowerCase();
  const password = String(form.get("password") ?? "");
  if (!email || !password) return { error: "Enter your email and password.", email };

  const supabase = await createSessionWriter();
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error || !data.user) return { error: "That email and password don't match.", email };

  const access = await resolvePartnerAccess(data.user.id);
  if (!access.ok) {
    await supabase.auth.signOut();
    return { error: DENIAL_WORDS[access.reason], email };
  }
  return { done: true };
}

/**
 * Accept an invitation: set a password, get a login, be signed in.
 *
 * The invitation names the email (the admin entered it); the partner only
 * chooses a password. Accepting a NEW invitation when the agent already has a
 * login resets that login's password — still a way back in for an agent whose
 * email does not arrive ("Forgot password" below is the usual one). An email that already belongs to some OTHER login
 * (an admin's, say) is refused, never linked.
 */
export async function acceptPartnerInvite(_prev: FormState, form: FormData): Promise<FormState> {
  const token = String(form.get("token") ?? "");
  const password = String(form.get("password") ?? "");
  const confirm = String(form.get("confirm") ?? "");
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) return { error: "This invitation link is incomplete. Open it again from the message Help24 sent you." };
  const problem = passwordProblem(password);
  if (problem) return { error: problem };
  if (password !== confirm) return { error: "The two passwords don't match." };

  const db = createServiceClient();
  const hash = await hashInviteToken(token);
  const { data: invite } = await db.from("partner_invites").select("agent_id, expires_at, used_at").eq("token_hash", hash).maybeSingle();
  if (!invite || invite.used_at || Date.parse(invite.expires_at) <= Date.now()) {
    return { error: "This invitation has expired or was already used — ask Help24 for a new one." };
  }
  const { data: agent } = await db.from("partner_agents").select("id, email, status").eq("id", invite.agent_id).maybeSingle();
  if (!agent?.email || agent.status !== "active") return { error: "This partner account isn't active. Contact Help24." };

  // Reset: the agent already has a login — give it the new password.
  const { data: existing } = await db.from("partner_logins").select("auth_subject").eq("agent_id", agent.id).maybeSingle();
  let subject: string;
  let created = false;
  if (existing?.auth_subject) {
    subject = existing.auth_subject as string;
    const { error } = await db.auth.admin.updateUserById(subject, { password, email: agent.email as string, email_confirm: true });
    if (error) return { error: "We couldn't set your password just now. Please try again." };
  } else {
    const { data: made, error } = await db.auth.admin.createUser({
      email: agent.email as string,
      password,
      email_confirm: true,
      app_metadata: { help24_partner: true },
    });
    if (error || !made.user) {
      const taken = /registered|exists/i.test(error?.message ?? "");
      return {
        error: taken
          ? "That email already has a different Help24 sign-in. Ask Help24 to use another email for your partner account."
          : "We couldn't create your sign-in just now. Please try again.",
      };
    }
    subject = made.user.id;
    created = true;
  }

  const { error: acceptError } = await db.rpc("partner_accept_invite", { p_token_hash: hash, p_auth_subject: subject });
  if (acceptError) {
    if (created) await db.auth.admin.deleteUser(subject);
    const m = /HELP24_PARTNER_[A-Z_]+:\s*(.+)$/.exec(acceptError.message);
    return { error: m ? m[1].charAt(0).toUpperCase() + m[1].slice(1) + "." : "We couldn't finish setting up your account. Please try again." };
  }

  const supabase = await createSessionWriter();
  const { error: signInError } = await supabase.auth.signInWithPassword({ email: agent.email as string, password });
  if (signInError) return { error: "Your account is ready, but signing in failed. Sign in with your email and new password." };
  return { done: true };
}

/** `sent` is the address the reset was asked for; the page says the same thing for every address. */
export type ResetState = { sent?: string; error?: string };

/**
 * Whether this address may get a partner reset email: an ACTIVE agent that
 * already has a login (an agent who never accepted an invitation has no
 * password to reset — their invitation is the way in). Null when it could not
 * be checked, which says nothing about the address.
 */
async function partnerMayReset(email: string): Promise<boolean | null> {
  const db = createServiceClient();
  const { data: agents, error } = await db.from("partner_agents").select("id, status").eq("email", email).limit(1);
  if (error) {
    console.error("[partners] reset lookup failed:", error.message);
    return null;
  }
  const agent = agents?.[0];
  if (!agent || agent.status !== "active") return false;
  const { data: logins, error: loginError } = await db.from("partner_logins").select("agent_id").eq("agent_id", agent.id).limit(1);
  if (loginError) {
    console.error("[partners] reset lookup failed:", loginError.message);
    return null;
  }
  return (logins ?? []).length > 0;
}

/**
 * "Forgot password" on the partner sign-in page. The server decides who gets
 * the email and every address gets the same answer (lib/password-reset.ts,
 * shared with the admin console). The link comes back to this host's
 * /auth/callback, which must be in Supabase's Redirect URLs.
 */
export async function requestPartnerPasswordReset(_prev: ResetState, form: FormData): Promise<ResetState> {
  const started = Date.now();
  const email = plausibleEmail(form.get("email"));
  if (!email) return { error: "Enter a valid email address." };

  const asked = await headers();
  const ip = asked.get("x-forwarded-for")?.split(",")[0]?.trim() || "unknown";
  if (tooManyResetRequests(`partner:${ip}`, started)) return { error: "Too many attempts. Wait a few minutes, then try again." };
  // The partner host, as the browser sees it (a server action's request URL can
  // carry the server's own host behind the rewrite — see ./signout).
  const origin = asked.get("origin");
  const eligible = origin ? await partnerMayReset(email) : null;
  if (!origin || eligible === null) return { error: "We couldn't send the reset email just now. Try again." };

  await sendResetUniformly({ email, eligible, redirectTo: recoveryRedirectUrl(origin), started });
  return { sent: email };
}
