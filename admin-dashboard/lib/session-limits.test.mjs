// node --test lib/session-limits.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { ABSOLUTE_LIMIT_MS, IDLE_LIMIT_MS, pastAbsoluteLimit, pastIdleLimit, signedInAt } from "./session-limits.ts";

const token = (payload) => `x.${Buffer.from(JSON.stringify(payload)).toString("base64url")}.y`;

test("sign-in time comes from the token's authentication times, newest first", () => {
  assert.equal(signedInAt(token({ amr: [{ method: "password", timestamp: 1_700_000_000 }] })), 1_700_000_000_000);
  assert.equal(signedInAt(token({ amr: [{ method: "password", timestamp: 1_700_000_000 }, { method: "otp", timestamp: 1_700_000_500 }] })), 1_700_000_500_000);
  assert.equal(signedInAt(token({ sub: "x" })), null);
  assert.equal(signedInAt("not-a-token"), null);
  assert.equal(signedInAt(null), null);
});

test("12 hours after signing in, sign in again", () => {
  const now = Date.now();
  assert.equal(pastAbsoluteLimit(now - ABSOLUTE_LIMIT_MS + 60_000, now), false);
  assert.equal(pastAbsoluteLimit(now - ABSOLUTE_LIMIT_MS - 60_000, now), true);
  assert.equal(pastAbsoluteLimit(null, now), false);
});

test("30 minutes idle signs out, but a fresh sign-in is never yesterday's idle tab", () => {
  const now = Date.now();
  assert.equal(pastIdleLimit(now - IDLE_LIMIT_MS - 1000, now - 5 * 3600e3, now), true);
  assert.equal(pastIdleLimit(now - IDLE_LIMIT_MS + 60_000, null, now), false);
  // Last touched yesterday, signed in a minute ago: not idle.
  assert.equal(pastIdleLimit(now - 86_400_000, now - 60_000, now), false);
  assert.equal(pastIdleLimit(null, null, now), false);
});
