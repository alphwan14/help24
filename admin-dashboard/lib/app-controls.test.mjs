// node --test lib/app-controls.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  compareVersions,
  controlProblems,
  describeChange,
  isRestrictive,
  minVersionProblems,
  nextAnnouncementId,
} from "./app-controls.ts";

const gate = (soft, hard, store_url = "https://help24.co.ke/download") => ({ soft, hard, message: "", store_url });

test("versions compare segment by segment, not as text", () => {
  assert.equal(compareVersions("1.0.10", "1.0.9"), 1);
  assert.equal(compareVersions("1.0.4", "1.0.5"), -1);
  assert.equal(compareVersions("2.0.0", "2.0.0"), 0);
});

test("a gate above the newest release is refused — it would lock everyone out", () => {
  assert.deepEqual(minVersionProblems(gate("1.0.5", "1.0.4"), "1.0.5"), []);
  const out = minVersionProblems(gate("1.0.6", "1.0.4"), "1.0.5");
  assert.equal(out.length, 1);
  assert.match(out[0], /1\.0\.6 has not been released/);
  // Unknown latest release: the check is skipped, not guessed.
  assert.deepEqual(minVersionProblems(gate("1.0.6", ""), null), []);
});

test("version gates must be comparable, ordered, and have somewhere to send people", () => {
  assert.match(minVersionProblems(gate("1.0", ""), null)[0], /like 1\.0\.5/);
  assert.match(minVersionProblems(gate("1.0.4", "1.0.5"), null)[0], /cannot be higher/);
  assert.match(minVersionProblems(gate("1.0.5", "", " "), null)[0], /Update button/);
  assert.deepEqual(minVersionProblems(gate("", "", ""), null), []);
});

test("a banner switched on without words is refused", () => {
  assert.equal(controlProblems("ops.maintenance", { active: true, message: "  " }, null).length, 1);
  assert.deepEqual(controlProblems("ops.maintenance", { active: false, message: "" }, null), []);
  assert.equal(controlProblems("ops.announcement", { active: true, message: "Hi", url: "http://x" }, null).length, 1);
});

test("the description names only what changes", () => {
  const before = { payments: true, promotions: true, posting: true, applications: true };
  assert.deepEqual(describeChange("ops.kill_switches", before, { ...before, payments: false }), ["Payments: on → off"]);
  assert.deepEqual(describeChange("ops.kill_switches", before, before), []);
  assert.deepEqual(
    describeChange("ops.min_version", gate("1.0.4", "1.0.4"), gate("1.0.5", "1.0.4")),
    ["Suggest update below: 1.0.4 → 1.0.5"],
  );
});

test("restrictive changes are the ones that take something away", () => {
  const on = { payments: true, promotions: true, posting: true, applications: true };
  assert.equal(isRestrictive("ops.kill_switches", on, { ...on, posting: false }), true);
  assert.equal(isRestrictive("ops.kill_switches", { ...on, posting: false }, on), false);
  assert.equal(isRestrictive("ops.maintenance", { active: false }, { active: true }), true);
  assert.equal(isRestrictive("ops.min_version", gate("", "1.0.4"), gate("", "1.0.5")), true);
  assert.equal(isRestrictive("ops.min_version", gate("1.0.4", "1.0.4"), gate("1.0.5", "1.0.4")), false);
});

test("announcement ids are new each time, so a reworded notice is shown again", () => {
  assert.notEqual(nextAnnouncementId(1), nextAnnouncementId(2));
  assert.match(nextAnnouncementId(), /^a-[0-9a-z]+$/);
});

test("a required version's reach among recent members", async () => {
  const { versionImpact } = await import("./app-controls.ts");
  const usage = { versions: [{ version: "1.0.6", count: 4 }, { version: "1.0.7", count: 2 }, { version: "1.0.10", count: 1 }], unreported: 5, windowDays: 30 };
  assert.deepEqual(versionImpact("1.0.7", usage), { known: 4, unreported: 5, certainUnreported: true });
  assert.deepEqual(versionImpact("1.0.11", usage).known, 7);
  // At or below 1.0.5 an unreported phone may already be on it.
  assert.equal(versionImpact("1.0.5", usage).certainUnreported, false);
  assert.equal(versionImpact("", usage).known, 0);
});
