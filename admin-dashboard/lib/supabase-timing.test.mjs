// node --test lib/supabase-timing.test.mjs
//
// The [sb] line must never carry a query string: PostgREST filters hold ids and
// email addresses (`users?email=eq.…`), and the line goes to Vercel's logs.
import assert from "node:assert/strict";
import { test } from "node:test";
import { sbLogLine } from "./supabase-timing.ts";

test("keeps the path and drops the query string", () => {
  const line = sbLogLine("get", "https://ref.supabase.co/rest/v1/users?select=id&email=eq.a%40b.co", 200, 23.4);
  assert.equal(line, "[sb] GET /rest/v1/users 200 23ms");
  assert.ok(!line.includes("email"));
});

test("an unparseable url still loses its query string", () => {
  assert.equal(sbLogLine("POST", "/rest/v1/rpc/x?id=1", 500, 7), "[sb] POST /rest/v1/rpc/x 500 7ms");
});

test("a network failure is logged with its duration", () => {
  assert.equal(sbLogLine("GET", "https://ref.supabase.co/auth/v1/user", "network-error", 1503.6), "[sb] GET /auth/v1/user network-error 1504ms");
});
