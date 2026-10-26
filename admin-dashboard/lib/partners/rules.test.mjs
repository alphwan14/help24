// node --test lib/partners/rules.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { hashInviteToken, maskName, maskPhone, memberStatus, newInviteToken, nextStep, summarise, weeklyCounts } from "./rules.ts";

const NOW = Date.parse("2026-10-26T12:00:00Z");
const D = 86400_000;
const row = (over = {}) => ({
  member_id: "m", agent_id: "a", method: "code",
  claimed_at: new Date(NOW - 2 * D).toISOString(),
  joined_at: new Date(NOW - 2 * D).toISOString(),
  window_ends_at: new Date(NOW + 12 * D).toISOString(),
  active_days: 0, posts_14d: 0, offers_14d: 0, account_status: "active",
  ...over,
});

test("qualifies on 2 days of use, or on one post or offer", () => {
  assert.equal(memberStatus(row({ active_days: 2 }), NOW), "qualified");
  assert.equal(memberStatus(row({ posts_14d: 1 }), NOW), "qualified");
  assert.equal(memberStatus(row({ offers_14d: 1, active_days: 1 }), NOW), "qualified");
  assert.equal(memberStatus(row({ active_days: 1 }), NOW), "in_progress");
});

test("a restricted account never qualifies", () => {
  assert.equal(memberStatus(row({ active_days: 5, account_status: "suspended" }), NOW), "in_progress");
  assert.equal(memberStatus(row({ active_days: 5, account_status: "banned", window_ends_at: new Date(NOW - D).toISOString() }), NOW), "not_qualified");
  assert.equal(memberStatus(row({ active_days: 5, account_status: "restricted" }), NOW), "qualified");
});

test("after 14 days an unqualified member stays unqualified", () => {
  assert.equal(memberStatus(row({ active_days: 1, window_ends_at: new Date(NOW - 1).toISOString() }), NOW), "not_qualified");
});

test("the next step says what is missing and how long is left", () => {
  assert.match(nextStep(row({ active_days: 1 }), NOW), /1 more day of using Help24.*12 days left/);
  assert.equal(nextStep(row({ active_days: 2 }), NOW), null);
});

test("summary and weekly counts", () => {
  const rows = [row({ active_days: 2, method: "qr" }), row({ method: "link" }), row({ claimed_at: new Date(NOW - 20 * D).toISOString(), window_ends_at: new Date(NOW - 6 * D).toISOString() })];
  const s = summarise(rows, NOW);
  assert.deepEqual([s.credited, s.qualified, s.inProgress, s.notQualified, s.thisWeek], [3, 1, 1, 1, 2]);
  assert.deepEqual(s.byMethod, { code: 1, link: 1, qr: 1 });
  const w = weeklyCounts(rows, 4, NOW);
  assert.equal(w.length, 4);
  assert.equal(w.reduce((n, x) => n + x.count, 0), 3);
  // NOW is a Monday: two days ago was the previous calendar week.
  assert.equal(w[2].count, 2);
});

test("agents see a first name and the last 3 digits — nothing more", () => {
  assert.equal(maskName("Wanjiru Kamau Otieno"), "Wanjiru");
  assert.equal(maskName("  "), "New member");
  assert.equal(maskPhone("+254 712 345 678"), "•••• ••• 678");
  assert.equal(maskPhone(null), "—");
});

test("invite tokens are random and only their hash is kept", async () => {
  const a = newInviteToken(), b = newInviteToken();
  assert.notEqual(a, b);
  assert.match(a, /^[A-Za-z0-9_-]{43}$/);
  const h = await hashInviteToken(a);
  assert.match(h, /^[0-9a-f]{64}$/);
  assert.equal(h, await hashInviteToken(a));
});
