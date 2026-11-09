// node --test lib/earnings.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { buildSeries, change, eatParts, kesShort, niceCeil, pick, viewFor } from "./earnings.ts";

// 10:30 in Nairobi on 9 Nov 2026 (07:30 UTC).
const NOW = new Date("2026-11-09T07:30:00Z");

test("days and hours are Nairobi's, not UTC's", () => {
  // 22:30 UTC on the 8th is 01:30 on the 9th in Nairobi.
  assert.deepEqual(eatParts(Date.parse("2026-11-08T22:30:00Z")).day, "2026-11-09");
  assert.equal(eatParts(Date.parse("2026-11-08T22:30:00Z")).hour, 1);
});

test("events land in the right hour, day and stream; future and out-of-window events are ignored", () => {
  const s = buildSeries(
    [
      { at: "2026-11-09T06:10:00Z", amount: 200, stream: "fees" }, // 09:10 today
      { at: "2026-11-09T06:50:00Z", amount: 500, stream: "promos" }, // 09:50 today
      { at: "2026-11-08T06:20:00Z", amount: 100, stream: "fees" }, // 09:20 yesterday
      { at: "2026-11-09T09:00:00Z", amount: 999, stream: "fees" }, // 12:00 today: later than now
      { at: "2026-08-01T00:00:00Z", amount: 999, stream: "fees" }, // outside 60 days
      { at: "2026-11-09T05:00:00Z", amount: 0, stream: "fees" }, // nothing earned
    ],
    NOW,
  );
  assert.deepEqual(s.today[9], { fees: 200, promos: 500 });
  assert.deepEqual(s.yesterday[9], { fees: 100, promos: 0 });
  assert.equal(s.days.length, 60);
  assert.deepEqual(s.days.at(-1), { day: "2026-11-09", fees: 200, promos: 500 });
  assert.deepEqual(s.days.at(-2), { day: "2026-11-08", fees: 100, promos: 0 });
});

test("today compares with yesterday only up to the same hour", () => {
  const s = buildSeries(
    [
      { at: "2026-11-09T05:00:00Z", amount: 300, stream: "fees" }, // 08:00 today
      { at: "2026-11-08T05:00:00Z", amount: 100, stream: "fees" }, // 08:00 yesterday
      { at: "2026-11-08T15:00:00Z", amount: 900, stream: "fees" }, // 18:00 yesterday: not yet comparable
    ],
    NOW,
  );
  const v = viewFor(s, "today");
  assert.equal(v.total.sum, 300);
  assert.equal(v.previousTotal.sum, 100);
  assert.equal(v.columns.length, 24);
  assert.ok(v.columns[10].current && !v.columns[10].future);
  assert.ok(v.columns[11].future);
});

test("week and month compare with the equal period before", () => {
  const ev = [];
  for (let d = 0; d < 14; d++) ev.push({ at: new Date(NOW.getTime() - d * 86400e3).toISOString(), amount: d < 7 ? 20 : 10, stream: "fees" });
  const s = buildSeries(ev, NOW);
  const w = viewFor(s, "week");
  assert.equal(w.columns.length, 7);
  assert.equal(w.total.sum, 140);
  assert.equal(w.previousTotal.sum, 70);
  assert.deepEqual(change(w.total.sum, w.previousTotal.sum), { pct: 100, up: true });
  assert.ok(w.columns.at(-1).current);
  assert.equal(viewFor(s, "month").columns.length, 30);
});

test("no comparison when the previous period earned nothing", () => {
  assert.equal(change(500, 0), null);
  assert.deepEqual(change(50, 100), { pct: 50, up: false });
});

test("axis ceilings and short money labels", () => {
  assert.equal(niceCeil(0), 100);
  assert.equal(niceCeil(730), 1000);
  assert.equal(niceCeil(2100), 2500);
  assert.equal(kesShort(950), "950");
  assert.equal(kesShort(1200), "1.2k");
  assert.equal(kesShort(25000), "25k");
  assert.equal(kesShort(3_400_000), "3.4M");
});

test("each stream can be read on its own, totals and previous period included", () => {
  const s = buildSeries(
    [
      { at: "2026-11-09T05:00:00Z", amount: 300, stream: "fees" },
      { at: "2026-11-09T05:30:00Z", amount: 1000, stream: "promos" },
      { at: "2026-11-08T05:00:00Z", amount: 200, stream: "fees" },
      { at: "2026-11-08T05:10:00Z", amount: 500, stream: "promos" },
    ],
    NOW,
  );
  const v = viewFor(s, "today");
  assert.equal(pick(v.total, "all"), 1300);
  assert.equal(pick(v.total, "fees"), 300);
  assert.equal(pick(v.total, "promos"), 1000);
  assert.equal(pick(v.previousTotal, "promos"), 500);
  assert.deepEqual(change(pick(v.total, "promos"), pick(v.previousTotal, "promos")), { pct: 100, up: true });
  assert.equal(pick(v.columns[8].previous, "fees"), 200);
});
