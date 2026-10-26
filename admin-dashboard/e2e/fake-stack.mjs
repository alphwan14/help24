// Local stand-in for the three services the dashboard talks to, for e2e/run.mjs:
//   /auth/v1/*  Supabase Auth (GoTrue): password + PKCE grants, sessions, the
//               "a password change signs out every OTHER session" rule, and a
//               mailer that renders the REAL recovery template from
//               supabase-auth-emails/html into an outbox.
//   /rest/v1/*  PostgREST — the two tables the admin gate reads.
//   /admin/*    the NestJS arbitration backend: me, session restore, invites.
//
// Faithful where it matters to the flows under test, and deliberately so in
// one place: accepting an invite creates the login and promotes the person by
// email but does NOT link the login to a Help24 identity — exactly like
// backend/src/admin/auth/admin-invites.service.ts. Nothing here talks to
// production.
import { createServer } from "node:http";
import { createHash, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

export async function startFakeStack({ port, siteUrl, redirectAllowList, templatesDir }) {
  const origin = `http://127.0.0.1:${port}`;
  const now = () => Math.floor(Date.now() / 1000);
  const b64 = (v) => Buffer.from(JSON.stringify(v)).toString("base64url");

  const auth = new Map(); // auth id → { id, email, password }
  const sessions = new Map(); // session id → { id, userId, createdAt, amr, refreshToken }
  const people = new Map(); // help24 id → { id, email, role }
  const links = []; // { subject: auth id, help24 }
  const admins = new Map(); // email → { id, email, name, role, active, token }
  const invites = new Map(); // token → { email, role, status, expiresAt }
  const recoveries = new Map(); // emailed token → { userId, challenge, redirectTo, sentAt, used }
  const flows = new Map(); // auth code → { userId, challenge }
  const outbox = [];
  const log = [];
  const restores = new Map();

  const recoveryTemplate = readFileSync(join(templatesDir, "recovery.html"), "utf8");
  const recoverySubject = JSON.parse(readFileSync(join(templatesDir, "manifest.json"), "utf8"))
    .find((t) => t.key === "recovery").subject;

  const byEmail = (email) =>
    [...auth.values()].find((u) => u.email.toLowerCase() === String(email ?? "").toLowerCase()) ?? null;
  const personByEmail = (email) =>
    [...people.values()].find((p) => p.email.toLowerCase() === String(email ?? "").toLowerCase()) ?? null;

  /** GoTrue's rule: the Site URL's host, or an allow-list entry; otherwise the Site URL itself. */
  function allowedRedirect(candidate) {
    try {
      const u = new URL(candidate);
      const site = new URL(siteUrl);
      if (u.protocol === site.protocol && u.host === site.host) return candidate;
      if (redirectAllowList.includes(candidate)) return candidate;
    } catch {}
    return siteUrl;
  }

  const userJson = (u) => ({
    id: u.id, aud: "authenticated", role: "authenticated", email: u.email,
    identities: [{ id: u.id, identity_id: u.id, user_id: u.id, provider: "email", identity_data: { email: u.email, sub: u.id } }],
    app_metadata: { provider: "email", providers: ["email"] }, user_metadata: {},
    created_at: "2026-06-01T08:00:00Z", last_sign_in_at: new Date().toISOString(),
  });
  function sessionJson(s) {
    const u = auth.get(s.userId);
    const iat = now();
    const claims = { sub: u.id, email: u.email, session_id: s.id, aud: "authenticated", role: "authenticated", aal: "aal1", amr: s.amr, iat, exp: iat + 3600 };
    return {
      access_token: [b64({ alg: "HS256", typ: "JWT" }), b64(claims), Buffer.from("sig").toString("base64url")].join("."),
      token_type: "bearer", expires_in: 3600, expires_at: iat + 3600, refresh_token: s.refreshToken, user: userJson(u),
    };
  }
  function issue(u, method) {
    const s = { id: randomUUID(), userId: u.id, createdAt: now(), amr: [{ method, timestamp: now() }], refreshToken: randomUUID() };
    sessions.set(s.id, s);
    return sessionJson(s);
  }
  function sessionFromToken(token) {
    try {
      const c = JSON.parse(Buffer.from(String(token).split(".")[1], "base64url").toString());
      const s = sessions.get(c.session_id);
      return s && c.exp > now() ? s : null;
    } catch {
      return null;
    }
  }
  const bearer = (req) => /^Bearer (.+)$/.exec(req.headers.authorization ?? "")?.[1] ?? null;
  function setPassword(user, password, keepSessionId) {
    user.password = password;
    for (const [id, s] of sessions) if (s.userId === user.id && id !== keepSessionId) sessions.delete(id);
  }

  /** admin-invites.service.ts → acceptInvite, minus the database. */
  function acceptInvite(token, name, password) {
    const inv = invites.get(token);
    if (!inv) return [404, "Invite not found."];
    if (inv.status === "completed") return [410, "This invitation has already been completed."];
    if (inv.expiresAt < Date.now()) return [410, "This invitation has expired."];
    if (!name || name.trim().length < 2) return [400, "Please provide your full name."];
    if (!password || password.length < 8) return [400, "Password must be at least 8 characters."];
    const existing = byEmail(inv.email);
    if (existing) setPassword(existing, password, null); // admin update: every session ends
    else {
      const id = randomUUID();
      auth.set(id, { id, email: inv.email, password });
    }
    const person = personByEmail(inv.email);
    if (person) person.role = "admin"; // promote an EXISTING person; never create, never link
    const token2 = "arb-" + randomUUID();
    const prior = admins.get(inv.email);
    admins.set(inv.email, { id: prior?.id ?? randomUUID(), email: inv.email, name: name.trim(), role: inv.role, active: true, token: token2 });
    inv.status = "completed";
    return [201, { email: inv.email, role: inv.role, token: token2, notice: "ok" }];
  }

  const server = createServer(async (req, res) => {
    const cors = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
      "Access-Control-Allow-Headers": req.headers["access-control-request-headers"] ?? "*",
      "Access-Control-Expose-Headers": "X-Supabase-Api-Version, Content-Range",
    };
    if (req.method === "OPTIONS") {
      res.writeHead(204, cors);
      return res.end();
    }
    const url = new URL(req.url, origin);
    let raw = "";
    for await (const c of req) raw += c;
    let body = {};
    try { body = raw ? JSON.parse(raw) : {}; } catch { body = {}; }
    const grant = url.searchParams.get("grant_type");
    log.push({ method: req.method, path: url.pathname + (grant ? `?grant_type=${grant}` : ""), select: url.searchParams.get("select") ?? "", body: raw });

    const send = (status, payload, headers = {}) => {
      res.writeHead(status, { "Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01", ...cors, ...headers });
      res.end(payload === undefined ? undefined : JSON.stringify(payload));
    };
    const authFail = (status, code, msg = `fake gotrue: ${code}`, extra = {}) => send(status, { code, msg, ...extra });
    const apiFail = (status, message) => send(status, { statusCode: status, message });
    const redirect = (location) => { res.writeHead(303, { Location: location }); res.end(); };
    const p = url.pathname;

    // ── GoTrue ──────────────────────────────────────────────────────────────
    if (req.method === "POST" && p === "/auth/v1/token") {
      if (grant === "password") {
        const u = byEmail(body.email);
        if (!u || u.password !== body.password) return authFail(400, "invalid_credentials", "Invalid login credentials");
        return send(200, issue(u, "password"));
      }
      if (grant === "pkce") {
        const f = flows.get(body.auth_code);
        if (!f) return authFail(404, "flow_state_not_found");
        if (createHash("sha256").update(body.code_verifier ?? "").digest("base64url") !== f.challenge) return authFail(400, "bad_code_verifier");
        flows.delete(body.auth_code);
        return send(200, issue(auth.get(f.userId), "recovery"));
      }
      if (grant === "refresh_token") {
        for (const s of sessions.values()) if (s.refreshToken === body.refresh_token) { s.refreshToken = randomUUID(); return send(200, sessionJson(s)); }
        return authFail(400, "refresh_token_not_found");
      }
      return authFail(400, "validation_failed");
    }
    if (p === "/auth/v1/user") {
      const s = sessionFromToken(bearer(req));
      if (!s) return authFail(403, "session_not_found");
      const u = auth.get(s.userId);
      if (req.method === "GET") return send(200, userJson(u));
      if (req.method === "PUT") {
        if (typeof body.password === "string") {
          if (Buffer.byteLength(body.password) > 72) return authFail(400, "validation_failed");
          if (body.password.length < 6) return authFail(422, "weak_password", undefined, { weak_password: { reasons: ["length"] } });
          if (body.password === u.password) return authFail(422, "same_password");
          setPassword(u, body.password, s.id); // GoTrue User.UpdatePassword → LogoutAllExceptMe
        }
        return send(200, userJson(u));
      }
    }
    if (req.method === "POST" && p === "/auth/v1/logout") {
      const s = sessionFromToken(bearer(req));
      if (s) sessions.delete(s.id);
      return send(204);
    }
    if (req.method === "POST" && p === "/auth/v1/recover") {
      const u = byEmail(body.email);
      // Like GoTrue: the same answer whether or not the address has an account.
      if (u) {
        const token = "pkce_" + randomUUID().replace(/-/g, "");
        const redirectTo = allowedRedirect(url.searchParams.get("redirect_to") ?? siteUrl);
        recoveries.set(token, { userId: u.id, challenge: body.code_challenge, redirectTo, sentAt: Date.now(), used: false });
        const link = `${origin}/auth/v1/verify?token=${token}&type=recovery&redirect_to=${encodeURIComponent(redirectTo)}`;
        outbox.push({
          to: u.email,
          subject: recoverySubject,
          link,
          token,
          html: recoveryTemplate.replaceAll("{{ .ConfirmationURL }}", link).replaceAll("{{ .Email }}", u.email),
        });
      }
      return send(200, {});
    }
    if (req.method === "GET" && p === "/auth/v1/verify") {
      // GoTrue's GET /verify for a PKCE token: check it, spend it, and send the
      // browser on with a one-time code. A bad token goes on with an error.
      const redirectTo = allowedRedirect(url.searchParams.get("redirect_to") ?? siteUrl);
      const r = recoveries.get(url.searchParams.get("token") ?? "");
      const target = new URL(redirectTo);
      if (!r || r.used || Date.now() - r.sentAt > 3600_000) {
        target.searchParams.set("error", "access_denied");
        target.searchParams.set("error_code", "otp_expired");
        return redirect(target.href);
      }
      r.used = true;
      const code = randomUUID();
      flows.set(code, { userId: r.userId, challenge: r.challenge });
      target.searchParams.set("code", code);
      return redirect(target.href);
    }

    // ── PostgREST (service role) ────────────────────────────────────────────
    if (req.method === "GET" && p.startsWith("/rest/v1/")) {
      const table = p.slice("/rest/v1/".length);
      const eq = (k) => url.searchParams.get(k)?.replace(/^eq\./, "");
      if (table === "user_auth_identities") {
        // Honours the `users(role)` embed the gate asks for (lib/admin-identity.ts),
        // as PostgREST does through the help24_user_id → users.id foreign key.
        const embedRole = (url.searchParams.get("select") ?? "").includes("users(");
        return send(200, eq("provider") === "supabase"
          ? links.filter((l) => l.subject === eq("subject")).map((l) => {
              const person = people.get(l.help24);
              return embedRole
                ? { help24_user_id: l.help24, users: person ? { role: person.role } : null }
                : { help24_user_id: l.help24 };
            })
          : []);
      }
      if (table === "users") {
        const person = people.get(eq("id"));
        return send(200, person ? [{ role: person.role }] : []);
      }
      return send(200, [], { "Content-Range": "0-0/0" });
    }

    // ── Arbitration backend ─────────────────────────────────────────────────
    const adminByToken = () => [...admins.values()].find((a) => a.token && a.token === bearer(req)) ?? null;
    if (req.method === "GET" && p === "/admin/me") {
      const a = adminByToken();
      return a ? send(200, { id: a.id, email: a.email, name: a.name, role: a.role }) : apiFail(401, "Invalid admin token.");
    }
    if (req.method === "POST" && p === "/admin/session/restore") {
      const s = sessionFromToken(body.accessToken);
      if (!s) return apiFail(401, "Your session could not be verified.");
      const email = auth.get(s.userId).email.toLowerCase();
      if (personByEmail(email)?.role !== "admin") return apiFail(403, "This account does not have admin access.");
      const a = admins.get(email);
      if (!a || !a.active) return apiFail(404, "No admin record found for this account.");
      a.token = "arb-" + randomUUID(); // one live token per admin: minting retires the last
      restores.set(email, (restores.get(email) ?? 0) + 1);
      return send(201, { email: a.email, name: a.name, role: a.role, token: a.token });
    }
    if (req.method === "GET" && p === "/admin/alerts") {
      return adminByToken() ? send(200, { generated_at: new Date().toISOString(), alerts: [], unavailable: [] }) : apiFail(401, "Invalid admin token.");
    }
    if (req.method === "GET" && p === "/admin/users") {
      return adminByToken()
        ? send(200, [...admins.values()].map((a) => ({ id: a.id, email: a.email, name: a.name, role: a.role, active: a.active, created_at: "2026-06-01T08:00:00Z", last_login_at: null })))
        : apiFail(401, "Invalid admin token.");
    }
    if (req.method === "GET" && p === "/admin/invites") return adminByToken() ? send(200, []) : apiFail(401, "Invalid admin token.");
    if (req.method === "GET" && p.startsWith("/admin/invite/")) {
      const inv = invites.get(decodeURIComponent(p.slice("/admin/invite/".length)));
      if (!inv) return apiFail(404, "Invite not found.");
      if (inv.status === "completed") return apiFail(410, "This invitation has already been completed.");
      if (inv.expiresAt < Date.now()) return apiFail(410, "This invitation has expired.");
      return send(200, { email: inv.email, role: inv.role, status: "validated", expires_at: new Date(inv.expiresAt).toISOString() });
    }
    if (req.method === "POST" && p === "/admin/accept-invite") {
      const [status, payload] = acceptInvite(body.token, body.name, body.password);
      return status < 300 ? send(status, payload) : apiFail(status, payload);
    }

    return send(404, { message: `fake: no route for ${req.method} ${p}` });
  });

  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));

  return {
    origin, server, log, outbox, restores, admins,
    addAuthUser(email, password) {
      const id = randomUUID();
      auth.set(id, { id, email, password });
      return id;
    },
    addPerson(email, role) {
      const id = "fb" + randomUUID().replace(/-/g, "").slice(0, 26);
      people.set(id, { id, email, role });
      return id;
    },
    /** The runbook's human step: link a credential to a person. */
    linkByEmail(email) {
      const u = byEmail(email);
      const person = personByEmail(email);
      links.push({ subject: u.id, help24: person.id });
    },
    addArbitrationAdmin(email, name, role, active = true) {
      admins.set(email, { id: randomUUID(), email, name, role, active, token: null });
    },
    addInvite(token, email, role, { expired = false } = {}) {
      invites.set(token, { email, role, status: "pending", expiresAt: Date.now() + (expired ? -1 : 7) * 86400e3 });
    },
    /** As if an earlier attempt had succeeded and its response had been lost. */
    acceptOutOfBand: (token, name, password) => acceptInvite(token, name, password),
    inviteStatus: (token) => invites.get(token)?.status,
    isLinked: (email) => links.some((l) => l.subject === byEmail(email)?.id),
    roleOf: (email) => personByEmail(email)?.role,
    password: (email) => byEmail(email)?.password,
    credentialCount: (email) => [...auth.values()].filter((u) => u.email.toLowerCase() === email.toLowerCase()).length,
    signInDirect(email, password) {
      const u = byEmail(email);
      return u && u.password === password ? issue(u, "password") : null;
    },
    isLive: (accessToken) => !!sessionFromToken(accessToken),
    expireRecoveryEmails() {
      for (const r of recoveries.values()) r.sentAt -= 2 * 3600_000;
    },
    lastEmailTo: (email) => [...outbox].reverse().find((m) => m.to === email) ?? null,
  };
}
