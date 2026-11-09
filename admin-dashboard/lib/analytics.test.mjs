// node --test lib/analytics.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { durationText, geography, growth, placeMatcher, revenue } from "./analytics.ts";
import { resolvePeriod, slotsFor } from "./periods.ts";

const NOW = new Date("2026-11-09T07:30:00Z");
const P = resolvePeriod("7d", NOW); // 3 Nov to 9 Nov, against 27 Oct to 2 Nov
const S = slotsFor(P, NOW.getTime());
const at = (d, h = 9) => new Date(Date.parse(`2026-${d}T00:00:00Z`) + (h - 3) * 3600e3).toISOString(); // Nairobi hour

test("revenue: earnings are fees on paid jobs plus promotion sales; failed and pending are kept apart", () => {
  const tx = [
    { created_at: at("11-04"), fee: 100, total_paid: 1100, amount: 1000, status: "paid", post_id: "a" },
    { created_at: at("11-05"), fee: 200, total_paid: 2200, amount: 2000, status: "released", post_id: "b" },
    { created_at: at("11-05"), fee: 50, total_paid: 550, status: "failed", post_id: "c" },
    { created_at: at("11-06"), fee: 70, total_paid: 770, status: "pending", post_id: "d" },
    { created_at: at("10-30"), fee: 150, total_paid: 1650, amount: 1500, status: "paid", post_id: "e" }, // before
  ];
  const promos = [{ paid_at: at("11-05"), created_at: at("11-05"), amount_kes: 500 }];
  const r = revenue(tx, promos, new Map([["a", "Plumbing"], ["b", "Cleaning"]]), P, S);
  assert.deepEqual(r.earnings, { now: 800, before: 150 });
  assert.deepEqual(r.volume, { now: 3300, before: 1650 });
  assert.equal(r.paidJobs.now, 2);
  assert.equal(r.failed.now, 550);
  assert.ok(Math.abs(r.takeRate.now - 300 / 3300) < 1e-9);
  assert.equal(r.avgJob.now, 1650);
  assert.deepEqual(r.daily[2].values, [200, 500]); // 5 Nov: fee and promotion
  assert.equal(r.daily[3].previous, 150); // 30 Oct sits at the same offset as 6 Nov
  assert.equal(r.categories[0].category, "Cleaning");
  assert.equal(r.best.index, 2);
});

test("growth: members, providers, actives, response and hire rates, first-response time", () => {
  const users = [
    { id: "u1", created_at: at("11-04"), profession: "Plumber" },
    { id: "u2", created_at: at("11-05"), profession: null },
    { id: "u3", created_at: at("10-29"), profession: "" },
  ];
  const active = [
    { member_id: "u1", day: "2026-11-04" },
    { member_id: "u1", day: "2026-11-05" },
    { member_id: "u2", day: "2026-11-05" },
    { member_id: "u3", day: "2026-10-29" },
  ];
  const posts = [
    { id: "r1", created_at: at("11-04", 9), type: "request", category: "Plumbing", status: "assigned", selected_provider_id: "u1" },
    { id: "r2", created_at: at("11-05", 9), type: "request", category: "Plumbing", status: "open" },
    { id: "r3", created_at: at("11-06", 9), type: "request", category: "Cleaning", status: "open" },
    { id: "o1", created_at: at("11-06", 9), type: "offer" },
  ];
  const apps = [
    { post_id: "r1", created_at: at("11-04", 11) }, // 2h
    { post_id: "r1", created_at: at("11-04", 10) }, // first: 1h
    { post_id: "r2", created_at: at("11-05", 13) }, // 4h
  ];
  const g = growth(users, active, posts, apps, [{ post_id: "r1", status: "paid" }], P, S);
  assert.deepEqual(g.members, { now: 2, before: 1 });
  assert.deepEqual(g.providers, { now: 1, before: 0 });
  assert.deepEqual(g.active, { now: 2, before: 1 });
  assert.equal(g.requests.now, 3);
  assert.equal(g.responded.now, 2);
  assert.equal(g.hired.now, 1);
  assert.equal(g.paid.now, 1);
  assert.ok(Math.abs(g.responseRate.now - 2 / 3) < 1e-9);
  assert.equal(durationText(g.medianWaitMs), "1h");
  assert.equal(g.categories[0].category, "Plumbing");
  assert.deepEqual(g.postsDaily[3].values, [1, 1]);
});

const REG = [
  { id: "nairobi", name: "Nairobi", kind: "city", parent_id: null, county: "Nairobi", latitude: -1.28, longitude: 36.81, aliases: ["nbo", "town"] },
  { id: "nairobi-westlands", name: "Westlands", kind: "area", parent_id: "nairobi", county: "Nairobi", latitude: -1.26, longitude: 36.81, aliases: [] },
  { id: "mombasa", name: "Mombasa", kind: "city", parent_id: null, county: "Mombasa", latitude: -4.04, longitude: 39.66, aliases: ["msa"] },
  { id: "nyali", name: "Nyali", kind: "area", parent_id: "mombasa", county: "Mombasa", latitude: -4.02, longitude: 39.71, aliases: [] },
];

test("places: the most specific match wins, areas roll up, generic words never match", () => {
  const m = placeMatcher(REG);
  assert.equal(m("Westlands, Nairobi").id, "nairobi");
  assert.equal(m("Nyali")?.id, "mombasa");
  assert.equal(m("near MSA ferry")?.id, "mombasa");
  assert.equal(m("in town"), null);
  assert.equal(m("Nyalikwa"), null); // whole words only
  assert.equal(m(""), null);
});

test("geography: demand, supply, response and money per place, with highlights", () => {
  const m = placeMatcher(REG);
  const posts = [
    { id: "r1", created_at: at("11-04"), type: "request", location: "Westlands", selected_provider_id: "x" },
    { id: "r2", created_at: at("11-05"), type: "request", location: "Nairobi" },
    { id: "r3", created_at: at("11-05"), type: "request", location: "Nairobi CBD" },
    { id: "r4", created_at: at("11-06"), type: "request", location: "Nyali" },
    { id: "o1", created_at: at("11-06"), type: "offer", location: "Nyali" },
    { id: "r5", created_at: at("10-30"), type: "request", location: "Mombasa" },
    { id: "x1", created_at: at("11-06"), type: "request", location: "Somewhere else" },
  ];
  const apps = [{ post_id: "r1", created_at: at("11-04", 10) }];
  const tx = [{ created_at: at("11-05"), fee: 100, total_paid: 1100, status: "paid", post_id: "r1" }];
  const g = geography(posts, apps, tx, m, P);
  const nbo = g.places.find((x) => x.id === "nairobi");
  assert.equal(nbo.requests, 3);
  assert.equal(nbo.responded, 1);
  assert.equal(nbo.hired, 1);
  assert.equal(nbo.fees, 100);
  const msa = g.places.find((x) => x.id === "mombasa");
  assert.deepEqual([msa.requests, msa.offers, msa.requestsBefore], [1, 1, 1]);
  assert.equal(g.unmatched, 1);
  assert.equal(g.underserved.id, "nairobi");
  assert.equal(g.counties[0].county, "Nairobi");
});
