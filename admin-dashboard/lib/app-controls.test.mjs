// node --test lib/app-controls.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  compareVersions,
  controlProblems,
  describeChange,
  downloadProblems,
  formatMegabytes,
  isRestrictive,
  minVersionProblems,
  nextAnnouncementId,
  SWITCHES,
  switchOn,
} from "./app-controls.ts";

const gate = (soft, hard, store_url = "https://help24.co.ke/download") => ({ soft, hard, message: "", store_url });

const APK = "https://github.com/alphwan14/help24/releases/download/v1.0.13/app-release.apk";
const SHA = "eae851787e4ddd249294f1cdbd1d738b598fd0d64eb8a0fac1740ae4fc1cdf9f";

test("the in-app download: all three fields or none, a link we publish, a real checksum and size", () => {
  assert.deepEqual(downloadProblems({ apk_url: "", sha256: "", size_bytes: 0 }), []);
  assert.deepEqual(downloadProblems({ apk_url: APK, sha256: SHA, size_bytes: 84986212 }), []);
  assert.deepEqual(downloadProblems({ apk_url: "https://help24.co.ke/download/help24.apk", sha256: SHA.toUpperCase(), size_bytes: 84986212 }), []);
  assert.match(downloadProblems({ apk_url: APK, sha256: "", size_bytes: 0 }).join(" "), /all three/);
  assert.match(downloadProblems({ apk_url: "https://evil.example/app.apk", sha256: SHA, size_bytes: 84986212 }).join(" "), /APK link/);
  assert.match(downloadProblems({ apk_url: APK.replace("https:", "http:"), sha256: SHA, size_bytes: 84986212 }).join(" "), /APK link/);
  assert.match(downloadProblems({ apk_url: APK, sha256: "abc", size_bytes: 84986212 }).join(" "), /SHA-256/);
  assert.match(downloadProblems({ apk_url: APK, sha256: SHA, size_bytes: 500 }).join(" "), /Size/);
  // A gate without the fields (an older backend) is not a problem.
  assert.deepEqual(minVersionProblems(gate("1.0.12", ""), "1.0.12"), []);
  assert.equal(formatMegabytes(84986212), "81.0 MB");
});

test("the confirm dialog names the in-app download when it changes", () => {
  const before = { ...gate("1.0.12", ""), apk_url: "", sha256: "", size_bytes: 0 };
  const after = { ...gate("1.0.13", ""), apk_url: APK, sha256: SHA, size_bytes: 84986212 };
  const lines = describeChange("ops.min_version", before, after);
  assert.ok(lines.some((l) => l.startsWith("In-app download:") && l.includes("81.0 MB") && l.includes("eae85178")), lines.join(" | "));
  assert.ok(describeChange("ops.min_version", after, before).includes("In-app download: off (Update opens the page)"));
});

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

test("the photo switch: absent reads as on, and switching it off is named", () => {
  const old = { payments: true, promotions: true, posting: true, applications: true };
  assert.equal(switchOn(old, "image_cdn"), true, "a backend that has not sent it yet means on");
  assert.equal(switchOn({ ...old, image_cdn: false }, "image_cdn"), false);
  assert.deepEqual(describeChange("ops.kill_switches", old, { ...old, image_cdn: true }), []);
  assert.deepEqual(describeChange("ops.kill_switches", { ...old, image_cdn: true }, { ...old, image_cdn: false }), [
    "Photos through Cloudflare: on → off",
  ]);
  assert.ok(SWITCHES.some((s) => s.key === "image_cdn"));
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
