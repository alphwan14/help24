// node --test lib/periods.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { PERIOD_OPTIONS, isPeriodKey, rangeLabel, resolvePeriod, slotIndex, slotsFor } from "./periods.ts";

const NOW = new Date("2026-11-09T07:30:00Z"); // Mon 9 Nov 2026, 10:30 Nairobi
const iso = (ms) => new Date(ms).toISOString();

test("today runs from Nairobi midnight, against yesterday up to the same time", () => {
  const p = resolvePeriod("today", NOW);
  assert.equal(iso(p.start), "2026-11-08T21:00:00.000Z");
  assert.equal(iso(p.prevStart), "2026-11-07T21:00:00.000Z");
  assert.equal(iso(p.prevEnd), "2026-11-08T07:30:00.000Z");
  assert.equal(p.bucket, "hour");
  assert.equal(slotsFor(p, NOW.getTime()).length, 24);
});

test("last 7 and 30 days include today and compare with the equal span before", () => {
  const w = resolvePeriod("7d", NOW);
  assert.equal(iso(w.start), "2026-11-02T21:00:00.000Z");
  assert.equal(w.prevEnd, w.start);
  assert.equal(w.start - w.prevStart, 7 * 86400e3);
  const slots = slotsFor(w);
  assert.equal(slots.length, 7);
  assert.equal(slots[0].short, "Tue");
  assert.equal(resolvePeriod("30d", NOW).bucket, "day");
});

test("this month compares with last month up to the same point; last month is a whole month", () => {
  const t = resolvePeriod("this_month", NOW);
  assert.equal(iso(t.start), "2026-10-31T21:00:00.000Z"); // 1 Nov, Nairobi
  assert.equal(iso(t.prevStart), "2026-09-30T21:00:00.000Z"); // 1 Oct
  assert.equal(t.prevEnd - t.prevStart, NOW.getTime() - t.start);
  const l = resolvePeriod("last_month", NOW);
  assert.equal(iso(l.start), "2026-09-30T21:00:00.000Z");
  assert.equal(iso(l.end), "2026-10-31T21:00:00.000Z");
  assert.equal(slotsFor(l).length, 31);
  assert.equal(rangeLabel(l), "1 Oct 2026 to 31 Oct 2026");
});

test("rolling months: days up to about four months, weeks beyond", () => {
  const m3 = resolvePeriod("3m", NOW);
  assert.equal(iso(m3.start), "2026-08-09T21:00:00.000Z"); // from 10 Aug
  assert.equal(m3.bucket, "day");
  const m6 = resolvePeriod("6m", NOW);
  assert.equal(m6.bucket, "week");
  const weeks = slotsFor(m6);
  assert.ok(weeks.length >= 26 && weeks.length <= 28, String(weeks.length));
  assert.equal(weeks[0].start, m6.start); // clipped to the period
  assert.ok(weeks.filter((w) => w.short).length <= 8);
  assert.equal(resolvePeriod("12m", NOW).prevEnd, resolvePeriod("12m", NOW).start);
});

test("slot lookup finds the slot holding an instant, and nothing outside", () => {
  const slots = slotsFor(resolvePeriod("7d", NOW));
  assert.equal(slotIndex(slots, Date.parse("2026-11-09T06:00:00Z")), 6);
  assert.equal(slotIndex(slots, Date.parse("2026-11-02T20:59:00Z")), -1);
});

test("every option resolves, and only known keys are accepted", () => {
  for (const o of PERIOD_OPTIONS) {
    const p = resolvePeriod(o.key, NOW);
    assert.ok(p.start < p.end && p.prevStart < p.prevEnd && p.prevEnd <= p.start + 1, o.key);
  }
  assert.ok(isPeriodKey("3m"));
  assert.ok(!isPeriodKey("99m"));
});
