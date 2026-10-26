// node --test lib/activity.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { activityState, agoLabel, lastActiveAt } from "./activity.ts";

const NOW = Date.parse("2026-10-26T12:00:00Z");
const ago = (ms) => new Date(NOW - ms).toISOString();
const S = 1000, M = 60 * S, H = 60 * M, D = 24 * H;

test("online only while the heartbeat behind the flag is fresh", () => {
  assert.equal(activityState({ is_online: true, last_seen: ago(60 * S) }, NOW), "online");
  // A crash leaves is_online stuck true — that is not "online".
  assert.equal(activityState({ is_online: true, last_seen: ago(10 * M) }, NOW), "today");
  assert.equal(activityState({ is_online: false, last_seen: ago(30 * S) }, NOW), "today");
});

test("the latest of heartbeat and sign-in decides the bucket", () => {
  assert.equal(activityState({ last_seen: ago(40 * D), last_login: ago(2 * D) }, NOW), "week");
  assert.equal(lastActiveAt({ last_seen: ago(3 * H), last_login: ago(5 * D) }), NOW - 3 * H);
});

test("buckets: today / week / month / inactive / dormant / never", () => {
  assert.equal(activityState({ last_seen: ago(23 * H) }, NOW), "today");
  assert.equal(activityState({ last_seen: ago(6 * D) }, NOW), "week");
  assert.equal(activityState({ last_seen: ago(29 * D) }, NOW), "month");
  assert.equal(activityState({ last_seen: ago(60 * D) }, NOW), "inactive");
  assert.equal(activityState({ last_login: ago(180 * D) }, NOW), "dormant");
  assert.equal(activityState({}, NOW), "never");
  assert.equal(activityState({ last_seen: "not a date" }, NOW), "never");
});

test("relative labels", () => {
  assert.equal(agoLabel(NOW - 20 * S, NOW), "just now");
  assert.equal(agoLabel(NOW - 12 * M, NOW), "12m ago");
  assert.equal(agoLabel(NOW - 3 * H, NOW), "3h ago");
  assert.equal(agoLabel(NOW - 2 * D, NOW), "2d ago");
  assert.equal(agoLabel(NOW - 35 * D, NOW), "5w ago");
  assert.equal(agoLabel(NOW - 180 * D, NOW), "6mo ago");
  assert.equal(agoLabel(null, NOW), "—");
});
