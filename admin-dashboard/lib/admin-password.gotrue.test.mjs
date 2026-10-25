// node --test lib/admin-password.gotrue.test.mjs
//
// The flows in admin-password.ts, driven through the REAL supabase-js client
// against a fake Supabase Auth (GoTrue) server that speaks its HTTP protocol:
// the same endpoints, status codes, error `code`s and session rules — above
// all, that a password update signs out every OTHER session of the account and
// keeps the one it ran under (GoTrue `User.UpdatePassword` → LogoutAllExceptMe).
//
// It is a fake. It proves the client-side flow and its handling of genuine
// provider responses; it says nothing about the live project's configuration.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { createServer } from "node:http";
import { after, before, beforeEach, describe, test } from "node:test";
import { createClient } from "@supabase/supabase-js";
import { changeOwnPassword, requestPasswordReset, resetOwnPassword } from "./admin-password.ts";
import { classifyRecoverySession } from "./recovery-session.ts";

const EMAIL = "alice@help24.co.ke";
const OLD = "correct horse 1";
const NEW = "Battery-staple-42";
const BOB_EMAIL = "bob@help24.co.ke";
const BOB_PASSWORD = "bobs own password 9";
const CALLBACK = "https://admin.example/auth/callback";

/* ── The fake ─────────────────────────────────────────────────────────────── */

function fakeGoTrue() {
  const users = new Map();
  const sessions = new Map();
  const recoveries = [];
  const flows = new Map();
  const log = [];
  const config = {};
  let attempts = 0;

  const now = () => Math.floor(Date.now() / 1000);
  const b64 = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");

  function reset() {
    users.clear();
    sessions.clear();
    recoveries.length = 0;
    flows.clear();
    log.length = 0;
    attempts = 0;
    Object.assign(config, {
      minLength: 6,
      requireReauth: false,
      requireCurrentPassword: false,
      rateLimitAfter: Infinity,
      dropUpdate: null,
    });
  }

  const userJson = (u) => ({
    id: u.id,
    aud: "authenticated",
    role: "authenticated",
    email: u.email,
    identities: [{ id: u.id, identity_id: u.id, user_id: u.id, provider: "email", identity_data: { email: u.email, sub: u.id } }],
    app_metadata: { provider: "email", providers: ["email"] },
    user_metadata: {},
    created_at: "2026-01-01T00:00:00Z",
  });

  function sessionJson(s) {
    const user = users.get(s.userId);
    const iat = now();
    const claims = { sub: user.id, email: user.email, session_id: s.id, aud: "authenticated", role: "authenticated", aal: "aal1", amr: s.amr, iat, exp: iat + 3600 };
    return {
      access_token: [b64({ alg: "HS256", typ: "JWT" }), b64(claims), Buffer.from("sig").toString("base64url")].join("."),
      token_type: "bearer",
      expires_in: 3600,
      expires_at: iat + 3600,
      refresh_token: s.refreshToken,
      user: userJson(user),
    };
  }

  function issue(user, method) {
    const s = { id: randomUUID(), userId: user.id, createdAt: now(), amr: [{ method, timestamp: now() }], refreshToken: randomUUID() };
    sessions.set(s.id, s);
    return sessionJson(s);
  }

  function sessionOf(req) {
    const bearer = /^Bearer (.+)$/.exec(req.headers.authorization ?? "")?.[1];
    if (!bearer) return null;
    try {
      const claims = JSON.parse(Buffer.from(bearer.split(".")[1], "base64url").toString());
      const s = sessions.get(claims.session_id);
      return s && claims.exp > now() ? s : null;
    } catch {
      return null;
    }
  }

  const byEmail = (email) =>
    [...users.values()].find((u) => u.email.toLowerCase() === String(email ?? "").toLowerCase()) ?? null;
  const isRecovery = (s) => s.amr.some((a) => ["recovery", "otp", "magiclink"].includes(a.method));

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, "http://fake");
    const grant = url.searchParams.get("grant_type");
    log.push(`${req.method} ${url.pathname}${grant ? `?grant_type=${grant}` : ""}`);
    let raw = "";
    for await (const chunk of req) raw += chunk;
    const body = raw ? JSON.parse(raw) : {};

    const send = (status, payload) => {
      res.writeHead(status, { "Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01" });
      res.end(payload === undefined ? undefined : JSON.stringify(payload));
    };
    const fail = (status, code, extra = {}) => send(status, { code, msg: `fake provider says ${code}`, ...extra });

    switch (`${req.method} ${url.pathname}`) {
      case "POST /auth/v1/token": {
        if (grant === "password") {
          if (++attempts > config.rateLimitAfter) return fail(429, "over_request_rate_limit");
          const user = byEmail(body.email);
          if (!user || user.password !== body.password) return fail(400, "invalid_credentials");
          return send(200, issue(user, "password"));
        }
        if (grant === "pkce") {
          const flow = flows.get(body.auth_code);
          if (!flow) return fail(404, "flow_state_not_found");
          if (createHash("sha256").update(body.code_verifier ?? "").digest("base64url") !== flow.challenge) {
            return fail(400, "bad_code_verifier");
          }
          flows.delete(body.auth_code);
          return send(200, issue(users.get(flow.userId), "recovery"));
        }
        return fail(400, "validation_failed");
      }
      case "GET /auth/v1/user": {
        const s = sessionOf(req);
        return s ? send(200, userJson(users.get(s.userId))) : fail(403, "session_not_found");
      }
      case "PUT /auth/v1/user": {
        const s = sessionOf(req);
        if (!s) return fail(403, "session_not_found");
        const user = users.get(s.userId);
        if (typeof body.password === "string") {
          if (config.dropUpdate === "before") return req.socket.destroy();
          if (config.requireCurrentPassword && !isRecovery(s)) {
            if (!body.current_password) return fail(400, "current_password_required");
            if (body.current_password !== user.password) return fail(400, "current_password_mismatch");
          }
          if (config.requireReauth && now() - s.createdAt > 24 * 3600 && !body.nonce) {
            return fail(400, "reauthentication_needed");
          }
          if (Buffer.byteLength(body.password) > 72) return fail(400, "validation_failed");
          if (body.password.length < config.minLength) {
            return fail(422, "weak_password", { weak_password: { reasons: ["length"] } });
          }
          if (body.password === user.password) return fail(422, "same_password");
          user.password = body.password;
          for (const [id, other] of sessions) if (other.userId === user.id && id !== s.id) sessions.delete(id);
          if (config.dropUpdate === "after") return req.socket.destroy();
        }
        return send(200, userJson(user));
      }
      case "POST /auth/v1/logout": {
        const s = sessionOf(req);
        if (s) sessions.delete(s.id);
        return send(204);
      }
      case "POST /auth/v1/recover": {
        const user = byEmail(body.email);
        // The same answer whether or not the address has an account.
        if (user) recoveries.push({ userId: user.id, challenge: body.code_challenge, redirectTo: url.searchParams.get("redirect_to") });
        return send(200, {});
      }
    }
    return fail(404, "not_found");
  });

  return {
    server,
    log,
    config,
    reset,
    get attempts() {
      return attempts;
    },
    addUser(email, password) {
      const id = randomUUID();
      users.set(id, { id, email, password });
      return id;
    },
    password: (id) => users.get(id).password,
    sessionsOf: (id) => [...sessions.values()].filter((s) => s.userId === id).length,
    revokeAllOf(id) {
      for (const [sid, s] of sessions) if (s.userId === id) sessions.delete(sid);
    },
    ageSessions(seconds) {
      for (const s of sessions.values()) s.createdAt -= seconds;
    },
    /** What GoTrue's /verify does when the emailed link is clicked: mint a code for the stored challenge. */
    followRecoveryLink() {
      const r = recoveries.at(-1);
      const code = randomUUID();
      flows.set(code, { userId: r.userId, challenge: r.challenge });
      return { code, redirectTo: r.redirectTo };
    },
    recoveryCount: () => recoveries.length,
  };
}

/* ── Harness ──────────────────────────────────────────────────────────────── */

const fake = fakeGoTrue();
let origin = "";
const printed = [];
const consoleMethods = ["log", "info", "warn", "error", "debug"];
const originals = {};

before(async () => {
  // Everything supabase-js prints (it console.errors failed fetches) is kept
  // for the last test, which checks no password ever appears in it.
  for (const m of consoleMethods) {
    originals[m] = console[m];
    console[m] = (...args) => printed.push(args.map((a) => (a instanceof Error ? `${a.stack} ${a.cause ?? ""}` : String(a))).join(" "));
  }
  await new Promise((resolve) => fake.server.listen(0, "127.0.0.1", resolve));
  origin = `http://127.0.0.1:${fake.server.address().port}`;
});

after(() => {
  for (const m of consoleMethods) console[m] = originals[m];
  fake.server.close();
});

beforeEach(() => fake.reset());

/** A browser-like client: its own stored session, nothing shared. */
const client = (auth = {}) =>
  createClient(origin, "anon-key", {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false, ...auth },
  });

async function signedIn(email, password, auth) {
  const c = client(auth);
  const { error } = await c.auth.signInWithPassword({ email, password });
  assert.equal(error, null, `sign-in for ${email}`);
  return c;
}

async function canSignIn(email, password) {
  const { error } = await client().auth.signInWithPassword({ email, password });
  return !error;
}

const whoIs = async (c) => (await c.auth.getUser()).data.user?.id ?? null;
const change = (over = {}) => ({ currentPassword: OLD, newPassword: NEW, confirmPassword: NEW, ...over });
const changeFrom = (browser, input = change()) => changeOwnPassword(browser.auth, () => client().auth, input);

/* ── Tests ────────────────────────────────────────────────────────────────── */

describe("changing a password from Settings, through supabase-js", () => {
  test("the new password works, the old one stops working, this browser stays signed in, every other device is signed out", async () => {
    const alice = fake.addUser(EMAIL, OLD);
    const otherDevice = await signedIn(EMAIL, OLD);
    const browser = await signedIn(EMAIL, OLD);

    assert.deepEqual(await changeFrom(browser), { ok: true, sessionKept: true });

    assert.equal(await whoIs(browser), alice, "this browser adopted the session the change ran under");
    assert.equal(await whoIs(otherDevice), null, "the other device was signed out by the provider");
    assert.equal(fake.sessionsOf(alice), 1, "exactly one session survives — this browser's");
    assert.equal(await canSignIn(EMAIL, OLD), false);
    assert.equal(await canSignIn(EMAIL, NEW), true);
  });

  test("another admin's password and sessions are untouched", async () => {
    fake.addUser(EMAIL, OLD);
    const bob = fake.addUser(BOB_EMAIL, BOB_PASSWORD);
    const bobsBrowser = await signedIn(BOB_EMAIL, BOB_PASSWORD);
    const browser = await signedIn(EMAIL, OLD);

    assert.equal((await changeFrom(browser)).ok, true);

    assert.equal(fake.password(bob), BOB_PASSWORD);
    assert.equal(await whoIs(bobsBrowser), bob);
  });

  test("a wrong current password changes nothing: no update sent, no session added or replaced", async () => {
    const alice = fake.addUser(EMAIL, OLD);
    const browser = await signedIn(EMAIL, OLD);
    const sessionsBefore = fake.sessionsOf(alice);

    const outcome = await changeFrom(browser, change({ currentPassword: "a confident guess 7" }));

    assert.equal(outcome.reason, "wrong_current_password");
    assert.equal(fake.password(alice), OLD);
    assert.ok(!fake.log.includes("PUT /auth/v1/user"));
    assert.equal(fake.sessionsOf(alice), sessionsBefore);
    assert.equal(await whoIs(browser), alice);
  });

  test("a session that has ended is refused before any password leaves the browser", async () => {
    const alice = fake.addUser(EMAIL, OLD);
    const browser = await signedIn(EMAIL, OLD);
    fake.revokeAllOf(alice);
    fake.log.length = 0;

    const outcome = await changeFrom(browser);

    assert.equal(outcome.reason, "session_expired");
    assert.deepEqual(fake.log, ["GET /auth/v1/user"]);
  });

  test("the provider's own strength rules are authoritative, and a refusal leaves no extra session behind", async () => {
    const alice = fake.addUser(EMAIL, OLD);
    fake.config.minLength = 20; // stricter than ours: NEW passes here, fails there
    const browser = await signedIn(EMAIL, OLD);
    const sessionsBefore = fake.sessionsOf(alice);

    const outcome = await changeFrom(browser);

    assert.equal(outcome.reason, "invalid");
    assert.match(outcome.fieldErrors.newPassword, /too short/);
    assert.equal(fake.password(alice), OLD);
    assert.equal(fake.sessionsOf(alice), sessionsBefore, "the verification session was signed out");
    assert.equal(await whoIs(browser), alice, "this browser's own session was never replaced");
  });

  test("'secure password change' (reauthenticate after 24 hours) is satisfied by the fresh sign-in, not bypassed", async () => {
    const alice = fake.addUser(EMAIL, OLD);
    fake.config.requireReauth = true;
    const browser = await signedIn(EMAIL, OLD);
    fake.ageSessions(25 * 3600);

    // The rule is live: the day-old session on its own may not do this.
    const direct = await browser.auth.updateUser({ password: NEW });
    assert.equal(direct.error?.code, "reauthentication_needed");

    assert.deepEqual(await changeFrom(browser), { ok: true, sessionKept: true });
    assert.equal(fake.password(alice), NEW);
  });

  test("'require current password' is satisfied too, because the update carries it", async () => {
    const alice = fake.addUser(EMAIL, OLD);
    fake.config.requireCurrentPassword = true;
    const browser = await signedIn(EMAIL, OLD);

    const direct = await browser.auth.updateUser({ password: NEW });
    assert.equal(direct.error?.code, "current_password_required");

    assert.equal((await changeFrom(browser)).ok, true);
    assert.equal(fake.password(alice), NEW);
  });

  test("the provider's rate limit is reported as such, with nothing changed", async () => {
    const alice = fake.addUser(EMAIL, OLD);
    const browser = await signedIn(EMAIL, OLD);
    fake.config.rateLimitAfter = fake.attempts;

    const outcome = await changeFrom(browser);

    assert.equal(outcome.reason, "rate_limited");
    assert.equal(fake.password(alice), OLD);
  });

  for (const when of ["before", "after"]) {
    test(`a connection lost ${when} the change is reported as UNKNOWN, and this browser stays signed in`, async () => {
      const alice = fake.addUser(EMAIL, OLD);
      const browser = await signedIn(EMAIL, OLD);
      fake.config.dropUpdate = when;

      const outcome = await changeFrom(browser);

      assert.equal(outcome.reason, "unknown_outcome");
      assert.equal(fake.password(alice), when === "after" ? NEW : OLD);
      fake.config.dropUpdate = null;
      assert.equal(await whoIs(browser), alice);
    });
  }
});

describe("recovering a forgotten password, through supabase-js", () => {
  test("the link's session sets a new password without the old one, and every other session ends", async () => {
    const alice = fake.addUser(EMAIL, OLD);
    const otherDevice = await signedIn(EMAIL, OLD);
    const browser = client({ flowType: "pkce" });

    assert.deepEqual(await requestPasswordReset(browser.auth, EMAIL, CALLBACK), { ok: true });
    const { code, redirectTo } = fake.followRecoveryLink();
    assert.equal(redirectTo, CALLBACK, "the email links to the callback, not to /login");

    // What app/auth/callback does with the code.
    assert.equal((await browser.auth.exchangeCodeForSession(code)).error, null);
    const { data } = await browser.auth.getClaims();
    assert.equal(classifyRecoverySession(data.claims, Date.now() / 1000), "recovery");

    assert.deepEqual(
      await resetOwnPassword(browser.auth, { newPassword: NEW, confirmPassword: NEW }),
      { ok: true, sessionKept: true },
    );
    assert.equal(await whoIs(browser), alice);
    assert.equal(await whoIs(otherDevice), null);
    assert.equal(await canSignIn(EMAIL, OLD), false);
    assert.equal(await canSignIn(EMAIL, NEW), true);
  });

  test("a link opened in a browser that never asked for it cannot be exchanged", async () => {
    fake.addUser(EMAIL, OLD);
    await requestPasswordReset(client({ flowType: "pkce" }).auth, EMAIL, CALLBACK);
    const { code } = fake.followRecoveryLink();

    const { error } = await client({ flowType: "pkce" }).auth.exchangeCodeForSession(code);
    // The callback turns exactly this into /reset-password?error=other-browser.
    assert.equal(error?.name, "AuthPKCECodeVerifierMissingError");
  });

  test("an ordinary signed-in session is not a recovery session", async () => {
    fake.addUser(EMAIL, OLD);
    const browser = await signedIn(EMAIL, OLD);
    const { data } = await browser.auth.getClaims();
    assert.equal(classifyRecoverySession(data.claims, Date.now() / 1000), "signed-in");
  });

  test("asking for a link answers the same whether or not the address has an account", async () => {
    fake.addUser(EMAIL, OLD);
    const known = await requestPasswordReset(client({ flowType: "pkce" }).auth, EMAIL, CALLBACK);
    const unknown = await requestPasswordReset(client({ flowType: "pkce" }).auth, "nobody@help24.co.ke", CALLBACK);
    assert.deepEqual(known, unknown);
    assert.equal(fake.recoveryCount(), 1);
  });
});

test("no password ever appeared in anything printed during these runs", () => {
  console.error("capture probe");
  assert.ok(printed.includes("capture probe"), "the console capture is live, so the check below means something");
  const everything = printed.join("\n");
  for (const secret of [OLD, NEW, BOB_PASSWORD]) {
    assert.ok(!everything.includes(secret), `"${secret}" was printed`);
  }
});
