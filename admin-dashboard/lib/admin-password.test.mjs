// node --test lib/admin-password.test.mjs   (Node ≥ 22.18: the .ts module loads through type stripping)
//
// The rules and the two flows against test doubles. The same flows run against
// the real supabase-js client and a GoTrue-protocol fake in
// admin-password.gotrue.test.mjs.
import assert from "node:assert/strict";
import { describe, test } from "node:test";
import {
  PASSWORD_MIN_LENGTH,
  STRENGTH_LABELS,
  changeOwnPassword,
  hasPasswordSignIn,
  passwordProblem,
  passwordRequirements,
  passwordStrength,
  requestPasswordReset,
  resetOwnPassword,
  validatePasswordChange,
  validatePasswordReset,
} from "./admin-password.ts";

const ALICE = { id: "alice-auth-id", email: "alice@help24.co.ke", identities: [{ provider: "email" }] };
const OLD = "correct horse 1";
const NEW = "Battery-staple-42";
const FRESH = { access_token: "fresh-access", refresh_token: "fresh-refresh" };
const PROSE = "raw provider prose that must never reach the screen";

const change = (over = {}) => ({ currentPassword: OLD, newPassword: NEW, confirmPassword: NEW, ...over });
const apiError = (code, status = 400, extra = {}) => ({ name: "AuthApiError", message: PROSE, code, status, ...extra });
const transportError = (status = 0) => ({ name: "AuthRetryableFetchError", message: PROSE, status });
const sessionMissing = () => ({ name: "AuthSessionMissingError", message: PROSE, status: 400 });

/**
 * A browser session client plus a throwaway-verifier factory, recording every
 * call in order. Each behaviour can be overridden per test.
 */
function harness({ user = ALICE, getUser, signIn, update, setSession } = {}) {
  const calls = [];
  const session = {
    async getUser() {
      calls.push(["getUser"]);
      if (getUser) return getUser();
      return { data: { user }, error: null };
    },
    async setSession(s) {
      calls.push(["setSession", s]);
      return setSession ? setSession(s) : { error: null };
    },
  };
  const createVerifier = () => ({
    async signInWithPassword(credentials) {
      calls.push(["signIn", credentials]);
      if (signIn) return signIn(credentials);
      return credentials.email === user.email && credentials.password === OLD
        ? { data: { user, session: FRESH }, error: null }
        : { data: { user: null, session: null }, error: apiError("invalid_credentials") };
    },
    async updateUser(attributes) {
      calls.push(["updateUser", attributes]);
      return update ? update(attributes) : { data: { user }, error: null };
    },
    async signOut(options) {
      calls.push(["signOut", options]);
      return { error: null };
    },
  });
  return { session, createVerifier, calls, names: () => calls.map((c) => c[0]) };
}

/** Nothing a person reads may carry a password or the provider's own wording. */
function assertNothingLeaks(outcome) {
  const shown = JSON.stringify(outcome);
  for (const secret of [OLD, NEW, PROSE]) assert.ok(!shown.includes(secret), `outcome leaked "${secret}": ${shown}`);
}

describe("the rules (parity with the app's AuthService)", () => {
  test("passwordProblem refuses what the app refuses, plus the provider's 72-byte ceiling", () => {
    assert.equal(passwordProblem(""), "Enter a password.");
    assert.equal(passwordProblem("abc123"), `Use at least ${PASSWORD_MIN_LENGTH} characters.`);
    assert.equal(passwordProblem("1234567890"), "Add letters as well as numbers.");
    assert.match(passwordProblem("a".repeat(73)), /too long/);
    // 37 characters but 74 bytes: the ceiling is bcrypt's, and bcrypt counts bytes.
    assert.match(passwordProblem("é".repeat(37)), /too long/);
    assert.equal(passwordProblem("a".repeat(72)), null);
    assert.equal(passwordProblem(NEW), null);
  });

  test("passwordStrength scores exactly as the app does, floored by the rule-check", () => {
    const cases = [
      ["", 0],
      ["abc", 0],
      ["12345678", 0], // long enough, refused anyway — the meter must not call it Okay
      ["abcdefgh", 1],
      ["abcdefghijkl", 2], // length
      ["Abcdefg1", 2], // three classes
      ["Abcdefghijk1", 3], // both
      ["correct horse battery", 2],
    ];
    for (const [password, score] of cases) {
      assert.equal(passwordStrength(password), score, `strength of "${password}"`);
    }
    assert.deepEqual([...STRENGTH_LABELS], ["Too weak", "Okay", "Good", "Strong"]);
  });

  test("the checklist tracks each rule, and compares with the current password only when given one", () => {
    const met = (items) => Object.fromEntries(items.map((r) => [r.id, r.met]));
    assert.deepEqual(met(passwordRequirements("")), { length: false, letters: false });
    assert.deepEqual(met(passwordRequirements("12345678")), { length: true, letters: false });
    assert.deepEqual(met(passwordRequirements(NEW, OLD)), { length: true, letters: true, different: true });
    assert.deepEqual(met(passwordRequirements(OLD, OLD)), { length: true, letters: true, different: false });
  });

  test("validatePasswordChange catches empty, mismatched and unchanged before any request", () => {
    assert.deepEqual(validatePasswordChange({ currentPassword: "", newPassword: "", confirmPassword: "" }), {
      currentPassword: "Enter your current password.",
      newPassword: "Enter a new password.",
      confirmPassword: "Re-enter your new password.",
    });
    assert.deepEqual(validatePasswordChange(change({ confirmPassword: NEW + "x" })), {
      confirmPassword: "The passwords don't match.",
    });
    assert.deepEqual(validatePasswordChange(change({ newPassword: OLD, confirmPassword: OLD })), {
      newPassword: "Your new password must be different from your current one.",
    });
    assert.deepEqual(validatePasswordChange(change({ newPassword: "12345678", confirmPassword: "12345678" })), {
      newPassword: "Add letters as well as numbers.",
    });
    assert.deepEqual(validatePasswordChange(change()), {});
  });

  test("validatePasswordReset has no current password to ask for", () => {
    assert.deepEqual(validatePasswordReset({ newPassword: NEW, confirmPassword: NEW }), {});
    assert.deepEqual(validatePasswordReset({ newPassword: "short", confirmPassword: "short" }), {
      newPassword: `Use at least ${PASSWORD_MIN_LENGTH} characters.`,
    });
  });

  test("hasPasswordSignIn: an email identity, or no identities to judge by", () => {
    assert.equal(hasPasswordSignIn(ALICE), true);
    assert.equal(hasPasswordSignIn({ id: "x", email: "x@y.z", identities: [] }), true);
    assert.equal(hasPasswordSignIn({ id: "x", email: "x@y.z" }), true);
    assert.equal(hasPasswordSignIn({ id: "x", email: "x@y.z", identities: [{ provider: "google" }] }), false);
    assert.equal(hasPasswordSignIn({ id: "x", email: null, identities: [{ provider: "email" }] }), false);
  });
});

describe("changeOwnPassword", () => {
  test("proves the current password as the SESSION's account, updates under that fresh session, then adopts it", async () => {
    const h = harness();
    const outcome = await changeOwnPassword(h.session, h.createVerifier, change());
    assert.deepEqual(outcome, { ok: true, sessionKept: true });
    assert.deepEqual(h.calls, [
      ["getUser"],
      ["signIn", { email: ALICE.email, password: OLD }],
      ["updateUser", { password: NEW, current_password: OLD }],
      ["setSession", FRESH],
    ]);
  });

  test("the update carries no account selector — no id, no email — only the passwords", async () => {
    const h = harness();
    await changeOwnPassword(h.session, h.createVerifier, change());
    const [, attributes] = h.calls.find((c) => c[0] === "updateUser");
    assert.deepEqual(Object.keys(attributes).sort(), ["current_password", "password"]);
  });

  for (const [name, input] of [
    ["empty fields", { currentPassword: "", newPassword: "", confirmPassword: "" }],
    ["a mismatched confirmation", change({ confirmPassword: "Battery-staple-43" })],
    ["an unchanged password", change({ newPassword: OLD, confirmPassword: OLD })],
    ["a too-short password", change({ newPassword: "abc", confirmPassword: "abc" })],
  ]) {
    test(`${name} never reaches the provider`, async () => {
      const h = harness();
      const outcome = await changeOwnPassword(h.session, h.createVerifier, input);
      assert.equal(outcome.ok, false);
      assert.equal(outcome.reason, "invalid");
      assert.deepEqual(h.calls, []);
    });
  }

  test("an expired session is refused before any password is sent", async () => {
    for (const getUser of [
      () => ({ data: { user: null }, error: sessionMissing() }),
      () => ({ data: { user: null }, error: null }),
      () => {
        throw new TypeError("fetch failed");
      },
    ]) {
      const h = harness({ getUser });
      const outcome = await changeOwnPassword(h.session, h.createVerifier, change());
      assert.equal(outcome.reason, "session_expired");
      assert.deepEqual(h.names(), ["getUser"]);
      assertNothingLeaks(outcome);
    }
  });

  test("an account with no password sign-in gets the support path, not a form that can only fail", async () => {
    const h = harness({ user: { ...ALICE, identities: [{ provider: "google" }] } });
    const outcome = await changeOwnPassword(h.session, h.createVerifier, change());
    assert.equal(outcome.reason, "no_password");
    assert.deepEqual(h.names(), ["getUser"]);
  });

  test("a wrong current password is a field error, and nothing is updated or replaced", async () => {
    const h = harness();
    const outcome = await changeOwnPassword(h.session, h.createVerifier, change({ currentPassword: "not it at all" }));
    assert.equal(outcome.reason, "wrong_current_password");
    assert.deepEqual(outcome.fieldErrors, { currentPassword: "That isn't your current password." });
    assert.deepEqual(h.names(), ["getUser", "signIn"]);
    assertNothingLeaks(outcome);
  });

  test("legacy wrong-password responses without a code are still recognised", async () => {
    const h = harness({
      signIn: () => ({
        data: { user: null, session: null },
        error: { name: "AuthApiError", status: 400, message: "Invalid login credentials" },
      }),
    });
    const outcome = await changeOwnPassword(h.session, h.createVerifier, change());
    assert.equal(outcome.reason, "wrong_current_password");
  });

  for (const [name, error, reason] of [
    ["rate limiting", apiError("over_request_rate_limit", 429), "rate_limited"],
    ["a bare 429", { name: "AuthApiError", status: 429, message: PROSE }, "rate_limited"],
    ["a banned account", apiError("user_banned"), "account_disabled"],
    ["a dropped connection", transportError(), "network"],
    ["a gateway error", transportError(503), "network"],
    ["anything else", apiError("unexpected_failure", 500), "provider"],
  ]) {
    test(`sign-in failure — ${name} — maps to ${reason} and changes nothing`, async () => {
      const h = harness({ signIn: () => ({ data: { user: null, session: null }, error }) });
      const outcome = await changeOwnPassword(h.session, h.createVerifier, change());
      assert.equal(outcome.reason, reason);
      assert.ok(outcome.message, "a person-readable message");
      assert.deepEqual(h.names(), ["getUser", "signIn"]);
      assertNothingLeaks(outcome);
    });
  }

  test("a sign-in that throws is a network failure, not a crash", async () => {
    const h = harness({
      signIn: () => {
        throw new TypeError("fetch failed");
      },
    });
    const outcome = await changeOwnPassword(h.session, h.createVerifier, change());
    assert.equal(outcome.reason, "network");
    assert.match(outcome.message, /nothing was changed/);
  });

  test("if the provider ever answered for a different account, the update does not run", async () => {
    const mallory = { id: "mallory-auth-id", email: ALICE.email, identities: [{ provider: "email" }] };
    const h = harness({ signIn: () => ({ data: { user: mallory, session: FRESH }, error: null }) });
    const outcome = await changeOwnPassword(h.session, h.createVerifier, change());
    assert.equal(outcome.reason, "identity_mismatch");
    assert.deepEqual(h.calls.slice(2), [["signOut", { scope: "local" }]]);
  });

  for (const [name, error, check] of [
    [
      "a weak password (too short for the project's rules)",
      { ...apiError("weak_password", 422), name: "AuthWeakPasswordError", reasons: ["length"] },
      (o) => assert.match(o.fieldErrors.newPassword, /too short/),
    ],
    [
      "a weak password (character rules)",
      { ...apiError("weak_password", 422), name: "AuthWeakPasswordError", reasons: ["characters"] },
      (o) => assert.match(o.fieldErrors.newPassword, /Mix upper- and lower-case/),
    ],
    [
      "a breached password",
      { ...apiError("weak_password", 422), name: "AuthWeakPasswordError", reasons: ["pwned"] },
      (o) => assert.match(o.fieldErrors.newPassword, /data breach/),
    ],
    [
      "the same password",
      apiError("same_password", 422),
      (o) => assert.match(o.fieldErrors.newPassword, /different from your current one/),
    ],
    [
      "an over-long password",
      apiError("validation_failed", 400),
      (o) => assert.ok(o.fieldErrors.newPassword),
    ],
    ["a reauthentication demand", apiError("reauthentication_needed"), (o) => assert.equal(o.reason, "reauth_required")],
    ["a lost session", sessionMissing(), (o) => assert.equal(o.reason, "session_expired")],
    ["a current-password check", apiError("current_password_mismatch"), (o) => assert.equal(o.reason, "wrong_current_password")],
    ["rate limiting", apiError("over_request_rate_limit", 429), (o) => assert.equal(o.reason, "rate_limited")],
  ]) {
    test(`update refused — ${name}: mapped, the extra session retired, this browser's left alone`, async () => {
      const h = harness({ update: () => ({ data: { user: null }, error }) });
      const outcome = await changeOwnPassword(h.session, h.createVerifier, change());
      assert.equal(outcome.ok, false);
      check(outcome);
      assert.deepEqual(h.names(), ["getUser", "signIn", "updateUser", "signOut"]);
      assertNothingLeaks(outcome);
    });
  }

  for (const [name, update] of [
    ["the connection drops", () => ({ data: { user: null }, error: transportError() })],
    ["a 504 arrives", () => ({ data: { user: null }, error: transportError(504) })],
    ["a 500 arrives", () => ({ data: { user: null }, error: apiError("unexpected_failure", 500) })],
    [
      "the call throws",
      () => {
        throw new TypeError("fetch failed");
      },
    ],
  ]) {
    test(`if ${name} mid-update, the outcome is UNKNOWN — never "nothing changed" — and this browser keeps a live session`, async () => {
      const h = harness({ update });
      const outcome = await changeOwnPassword(h.session, h.createVerifier, change());
      assert.equal(outcome.reason, "unknown_outcome");
      assert.doesNotMatch(outcome.message, /nothing was changed/i);
      assert.deepEqual(h.calls.at(-1), ["setSession", FRESH]);
      assert.ok(!h.names().includes("signOut"));
    });
  }

  test("a change that landed but could not be adopted here is still reported as a change", async () => {
    const h = harness({ setSession: () => ({ error: sessionMissing() }) });
    const outcome = await changeOwnPassword(h.session, h.createVerifier, change());
    assert.deepEqual(outcome, { ok: true, sessionKept: false });
  });
});

describe("resetOwnPassword", () => {
  function recovery({ user = ALICE, getUser, update } = {}) {
    const calls = [];
    const auth = {
      async getUser() {
        calls.push(["getUser"]);
        return getUser ? getUser() : { data: { user }, error: null };
      },
      async updateUser(attributes) {
        calls.push(["updateUser", attributes]);
        return update ? update(attributes) : { data: { user }, error: null };
      },
    };
    return { auth, calls };
  }

  test("sets the new password on the recovery session — and sends nothing else", async () => {
    const r = recovery();
    const outcome = await resetOwnPassword(r.auth, { newPassword: NEW, confirmPassword: NEW });
    assert.deepEqual(outcome, { ok: true, sessionKept: true });
    assert.deepEqual(r.calls, [["getUser"], ["updateUser", { password: NEW }]]);
  });

  test("invalid input never reaches the provider", async () => {
    const r = recovery();
    const outcome = await resetOwnPassword(r.auth, { newPassword: NEW, confirmPassword: "nope" });
    assert.equal(outcome.reason, "invalid");
    assert.deepEqual(r.calls, []);
  });

  test("no session means the link has expired, and no update is attempted", async () => {
    const r = recovery({ getUser: () => ({ data: { user: null }, error: sessionMissing() }) });
    const outcome = await resetOwnPassword(r.auth, { newPassword: NEW, confirmPassword: NEW });
    assert.equal(outcome.reason, "session_expired");
    assert.deepEqual(r.calls, [["getUser"]]);
  });

  test("the provider's strength rules still apply", async () => {
    const r = recovery({
      update: () => ({
        data: { user: null },
        error: { ...apiError("weak_password", 422), name: "AuthWeakPasswordError", reasons: ["characters"] },
      }),
    });
    const outcome = await resetOwnPassword(r.auth, { newPassword: NEW, confirmPassword: NEW });
    assert.ok(outcome.fieldErrors.newPassword);
    assertNothingLeaks(outcome);
  });
});

describe("requestPasswordReset", () => {
  function resetter(result) {
    const calls = [];
    const auth = {
      async resetPasswordForEmail(email, options) {
        calls.push([email, options]);
        if (result instanceof Error) throw result;
        return result ?? { data: {}, error: null };
      },
    };
    return { auth, calls };
  }

  test("asks for the email with the callback as the redirect", async () => {
    const r = resetter();
    const outcome = await requestPasswordReset(r.auth, "  alice@help24.co.ke ", "https://admin.example/auth/callback");
    assert.deepEqual(outcome, { ok: true });
    assert.deepEqual(r.calls, [["alice@help24.co.ke", { redirectTo: "https://admin.example/auth/callback" }]]);
  });

  test("an empty address is refused locally", async () => {
    const r = resetter();
    const outcome = await requestPasswordReset(r.auth, "   ", "https://admin.example/auth/callback");
    assert.equal(outcome.ok, false);
    assert.deepEqual(r.calls, []);
  });

  for (const [name, result, pattern] of [
    ["email rate limit", { error: apiError("over_email_send_rate_limit", 429) }, /Too many reset emails/],
    ["a dropped connection", { error: transportError() }, /couldn't reach/],
    ["a thrown error", new TypeError("fetch failed"), /couldn't reach/],
    ["anything else", { error: apiError("unexpected_failure", 500) }, /couldn't send/],
  ]) {
    test(`${name} gets its own message, never the provider's`, async () => {
      const r = resetter(result);
      const outcome = await requestPasswordReset(r.auth, "alice@help24.co.ke", "https://admin.example/auth/callback");
      assert.equal(outcome.ok, false);
      assert.match(outcome.message, pattern);
      assert.ok(!outcome.message.includes(PROSE));
    });
  }
});
