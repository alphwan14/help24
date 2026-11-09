// node --test lib/nav.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";
import { existsSync } from "node:fs";
import { NAV, activePageHref, attentionBySection, badgeText, sectionFor, sectionById } from "./nav.ts";

test("every nav page is a real route", () => {
  for (const s of NAV) {
    for (const p of s.pages) {
      const path = p.href.split("?")[0].replace(/^\//, "");
      assert.ok(existsSync(new URL(`../app/${path}/page.tsx`, import.meta.url)), `${p.href} has no page`);
    }
  }
});

test("each section opens on one of its own pages", () => {
  for (const s of NAV) assert.ok(s.pages.some((p) => p.href === s.href), s.id);
});

test("sections are found by path, including detail pages", () => {
  assert.equal(sectionFor("/dashboard/disputes/abc-123")?.id, "disputes");
  assert.equal(sectionFor("/dashboard/trust-safety/users/9")?.id, "trust-safety");
  assert.equal(sectionFor("/dashboard/settings"), null);
  assert.equal(sectionFor("/dashboard/usersx"), null);
});

test("the most specific page wins, and query pages need their query", () => {
  const promo = sectionById("promotion").pages;
  assert.equal(activePageHref(promo, "/dashboard/promotion", new URLSearchParams("")), "/dashboard/promotion");
  assert.equal(
    activePageHref(promo, "/dashboard/promotion", new URLSearchParams("status=pending_review")),
    "/dashboard/promotion?status=pending_review",
  );
  assert.equal(activePageHref(promo, "/dashboard/promotion/abc", null), "/dashboard/promotion");
  const pay = sectionById("payments").pages;
  assert.equal(activePageHref(pay, "/dashboard/payments/failed", null), "/dashboard/payments/failed");
});

test("nav counts: open high and medium alerts only, grouped by where they link", () => {
  const alerts = [
    { id: "a", priority: "high", count: 2, href: "/dashboard/disputes?status=escalated" },
    { id: "b", priority: "medium", count: 3, href: "/dashboard/disputes" },
    { id: "c", priority: "low", count: 9, href: "/dashboard/marketplace/active-jobs" },
    { id: "d", priority: "high", count: 4, href: "/dashboard/payments/failed", review: { note: "ok" } },
    { id: "e", priority: "medium", count: 1, href: "/dashboard/users/admins#unlinked-logins" },
  ];
  const by = attentionBySection(alerts);
  assert.deepEqual(by.disputes, { count: 5, high: true });
  assert.deepEqual(by.users, { count: 1, high: false });
  assert.equal(by.marketplace, undefined);
  assert.equal(by.payments, undefined);
});

test("badges stop at 99+", () => {
  assert.equal(badgeText(7), "7");
  assert.equal(badgeText(100), "99+");
});

test("no em dashes or middle dots in nav labels", () => {
  const src = readFileSync(new URL("./nav.ts", import.meta.url), "utf8");
  const labels = [...src.matchAll(/label: "([^"]+)"/g)].map((m) => m[1]);
  for (const l of labels) assert.ok(!/[—·]/.test(l), l);
});
