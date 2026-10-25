// node --test lib/invite-email-binding.test.mjs   (Node ≥ 22.18: the .ts module loads through type stripping)
import assert from "node:assert/strict";
import { test } from "node:test";

process.env.SUPABASE_SERVICE_ROLE_KEY = "test-service-key";
const { isInvitedEmail, signInvitedEmail } = await import("./invite-email-binding.ts");

test("the address the server rendered for an invitation verifies — case and padding aside", () => {
  const sig = signInvitedEmail("tok-1", "dave@help24.co.ke");
  assert.equal(isInvitedEmail("tok-1", "dave@help24.co.ke", sig), true);
  assert.equal(isInvitedEmail("tok-1", " Dave@Help24.co.ke ", sig), true);
});

test("a different address, a different invitation, or a forged signature does not", () => {
  const sig = signInvitedEmail("tok-1", "dave@help24.co.ke");
  assert.equal(isInvitedEmail("tok-1", "mallory@evil.test", sig), false);
  assert.equal(isInvitedEmail("tok-2", "dave@help24.co.ke", sig), false);
  assert.equal(isInvitedEmail("tok-1", "dave@help24.co.ke", sig.slice(0, -2) + "AA"), false);
  assert.equal(isInvitedEmail("tok-1", "dave@help24.co.ke", ""), false);
  assert.equal(isInvitedEmail("tok-1", "dave@help24.co.ke", "x"), false);
});

test("without the server secret nothing is signed and nothing verifies", () => {
  const sig = signInvitedEmail("tok-1", "dave@help24.co.ke");
  delete process.env.SUPABASE_SERVICE_ROLE_KEY;
  assert.equal(signInvitedEmail("tok-1", "dave@help24.co.ke"), null);
  assert.equal(isInvitedEmail("tok-1", "dave@help24.co.ke", sig), false);
  process.env.SUPABASE_SERVICE_ROLE_KEY = "test-service-key";
});

test("the key is the service key's, but the signature reveals nothing about it", () => {
  const sig = signInvitedEmail("tok-1", "dave@help24.co.ke");
  assert.ok(!sig.includes("test-service-key"));
  process.env.SUPABASE_SERVICE_ROLE_KEY = "another-key";
  assert.equal(isInvitedEmail("tok-1", "dave@help24.co.ke", sig), false);
  process.env.SUPABASE_SERVICE_ROLE_KEY = "test-service-key";
});
