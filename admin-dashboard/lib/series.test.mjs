// node --test lib/series.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { fillDays, lastDays } from "./series.ts";

const NOW = new Date("2026-11-09T05:00:00Z");

test("the window ends today and runs oldest first", () => {
  const d = lastDays(3, NOW);
  assert.deepEqual(d, [
    { key: "11-07", label: "7 Nov" },
    { key: "11-08", label: "8 Nov" },
    { key: "11-09", label: "9 Nov" },
  ]);
});

test("missing days are zero and present days keep their values", () => {
  const rows = [{ date: "11-08", requests: 0, offers: 1 }, { date: "10-01", requests: 5, offers: 5 }];
  const out = fillDays(rows, { requests: 0, offers: 0 }, 3, NOW);
  assert.deepEqual(out, [
    { date: "7 Nov", requests: 0, offers: 0 },
    { date: "8 Nov", requests: 0, offers: 1 },
    { date: "9 Nov", requests: 0, offers: 0 },
  ]);
});

test("a window across New Year", () => {
  const d = lastDays(2, new Date("2027-01-01T10:00:00Z"));
  assert.deepEqual(d.map((x) => x.label), ["31 Dec", "1 Jan"]);
});
