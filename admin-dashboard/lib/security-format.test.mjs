// node --test lib/security-format.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  authAction,
  authMethod,
  categoryFilter,
  describeDevice,
  describePlace,
  eventCategory,
  eventLabel,
  memberMethod,
  personFilter,
  refusalReason,
  typeChangeLabel,
  whoFilter,
} from "./security-format.ts";

test("devices are named the way people say them", () => {
  assert.equal(
    describeDevice("Mozilla/5.0 (Linux; Android 14; SM-G986B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36"),
    "Chrome on Android",
  );
  assert.equal(
    describeDevice("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"),
    "Safari on iPhone",
  );
  assert.equal(
    describeDevice("Mozilla/5.0 (Linux; Android 14; SAMSUNG SM-G986B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/26.0 Chrome/122.0 Mobile Safari/537.36"),
    "Samsung Internet on Android",
  );
  assert.equal(describeDevice("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36 Edg/130.0"), "Edge on Windows");
  assert.equal(describeDevice("Dart/3.5 (dart:io)"), "Help24 app");
  assert.equal(describeDevice("curl/8.0"), "Unknown device");
  assert.equal(describeDevice(null), null);
});

test("places read as city, country", () => {
  assert.equal(describePlace("KE", "Nairobi"), "Nairobi, Kenya");
  assert.equal(describePlace("UG", null), "Uganda");
  assert.equal(describePlace(null, null), null);
});

test("every recorded event has words", () => {
  assert.equal(eventLabel("console.opened"), "Opened the console");
  assert.equal(eventLabel("sign_in.failed"), "Failed to sign in");
  assert.equal(eventLabel("member.signed_in"), "Signed in to the app");
  assert.equal(eventCategory("member.signed_in"), "sign_in");
  assert.equal(memberMethod("phone"), "with phone number");
  assert.equal(memberMethod("google.com"), "with Google");
  assert.equal(memberMethod("custom"), null);
});

test("Supabase Auth actions become plain sentences, refreshes never appear", () => {
  assert.deepEqual(authAction("login"), { label: "Signed in", category: "sign_in" });
  assert.equal(authAction("user_updated_password").label, "Changed their password");
  assert.equal(authAction("user_recovery_requested").category, "account");
  assert.equal(authMethod("google"), "with Google");
  assert.equal(authMethod("email"), "with password");
});

test("refusals say why", () => {
  assert.equal(refusalReason("403"), "Not an active admin");
  assert.equal(refusalReason("invalid_credentials"), "Wrong email or password");
  assert.equal(refusalReason(null), null);
});

test("filters accept only what they know", () => {
  assert.equal(whoFilter("member"), "member");
  assert.equal(whoFilter("root"), "all");
  assert.equal(categoryFilter("failed"), "failed");
  assert.equal(categoryFilter("x"), "all");
  assert.deepEqual(personFilter("member:abc123XYZ"), { kind: "member", id: "abc123XYZ" });
  assert.equal(personFilter("admin:not-a-uuid"), null);
  assert.equal(personFilter("member:a,b"), null);
  assert.deepEqual(personFilter("admin:3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90"), { kind: "admin", id: "3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90" });
});

test("no em dash or middle dot in any label", () => {
  assert.doesNotMatch(typeChangeLabel("request", "offer"), /[—·]/);
});
