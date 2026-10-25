// node --test lib/recovery-session.test.mjs   (Node ≥ 22.18: the .ts module loads through type stripping)
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  RECOVERY_WINDOW_SECONDS,
  classifyRecoverySession,
  parseRecoveryLinkError,
  recoveryRedirectUrl,
} from "./recovery-session.ts";

const NOW = 1_800_000_000;
const amr = (...entries) => ({ sub: "alice-auth-id", email: "alice@help24.co.ke", amr: entries });

test("the reset link returns to the callback on the origin that asked — not to /login", () => {
  assert.equal(recoveryRedirectUrl("https://admin.help24.co.ke"), "https://admin.help24.co.ke/auth/callback");
  assert.equal(recoveryRedirectUrl("http://localhost:3001/"), "http://localhost:3001/auth/callback");
  assert.doesNotMatch(recoveryRedirectUrl("https://admin.help24.co.ke"), /login|password-updated/);
});

test("only the callback's own two error words survive the query string", () => {
  assert.equal(parseRecoveryLinkError("link-invalid"), "link-invalid");
  assert.equal(parseRecoveryLinkError("other-browser"), "other-browser");
  for (const junk of [undefined, null, "", "<script>", "LINK-INVALID", "access_denied"]) {
    assert.equal(parseRecoveryLinkError(junk), null);
  }
});

test("no claims: no session at all", () => {
  assert.equal(classifyRecoverySession(null, NOW), "none");
  assert.equal(classifyRecoverySession(undefined, NOW), "none");
  assert.equal(classifyRecoverySession("token", NOW), "none");
});

test("a password sign-in is an ordinary session — this page is not a way around the current password", () => {
  assert.equal(classifyRecoverySession(amr({ method: "password", timestamp: NOW - 5 }), NOW), "signed-in");
  assert.equal(classifyRecoverySession({ sub: "x" }, NOW), "signed-in");
});

test("a fresh session from a reset link may set a password", () => {
  assert.equal(classifyRecoverySession(amr({ method: "recovery", timestamp: NOW - 30 }), NOW), "recovery");
});

test("recovery means what it means to the provider: recovery, otp and magiclink", () => {
  for (const method of ["recovery", "otp", "magiclink"]) {
    assert.equal(classifyRecoverySession(amr({ method, timestamp: NOW }), NOW), "recovery", method);
  }
  for (const method of ["password", "oauth", "totp", "token_refresh", "invite"]) {
    assert.equal(classifyRecoverySession(amr({ method, timestamp: NOW }), NOW), "signed-in", method);
  }
});

test("the form closes when the link's window does, even though the session lives on", () => {
  const edge = amr({ method: "recovery", timestamp: NOW - RECOVERY_WINDOW_SECONDS });
  const late = amr({ method: "recovery", timestamp: NOW - RECOVERY_WINDOW_SECONDS - 1 });
  assert.equal(classifyRecoverySession(edge, NOW), "recovery");
  assert.equal(classifyRecoverySession(late, NOW), "signed-in");
});

test("any qualifying entry counts, and malformed entries are skipped rather than trusted", () => {
  const mixed = amr(
    { method: "password", timestamp: NOW - 10 },
    null,
    "recovery",
    { method: "recovery", timestamp: "recently" },
    { method: "recovery", timestamp: NOW - 20 },
  );
  assert.equal(classifyRecoverySession(mixed, NOW), "recovery");
  assert.equal(classifyRecoverySession({ amr: "recovery" }, NOW), "signed-in");
  assert.equal(classifyRecoverySession({ amr: [{ method: "recovery" }] }, NOW), "signed-in");
});
