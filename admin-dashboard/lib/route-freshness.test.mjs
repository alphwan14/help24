// node --test lib/route-freshness.test.mjs
//
// A dashboard page that reads the database but nothing request-specific is
// prerendered by Next ONCE, at build time, and then served unchanged until the
// next deploy. Twelve pages did exactly that until 2026-10-26 — Vercel's build
// machine ran their queries during the deploy and production never ran them
// again. A page that reads data must therefore say how fresh it is.
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const DASHBOARD = join(ROOT, "app", "dashboard");

function pages(dir) {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) return pages(p);
    return name === "page.tsx" ? [p] : [];
  });
}

const READS_DATA = /createServiceClient|\.from\(["']/;
// Any of these makes a page dynamic on its own, so it is rendered per request.
const REQUEST_SPECIFIC = /getSessionUser|getCurrentAdmin|cookies\(|headers\(|searchParams/;
// A page export, or a cached loader with an explicit window (overview/page.tsx
// caches its data with unstable_cache({ revalidate: 60 }), which Next applies to
// the route too).
const SAYS_HOW_FRESH = /export const (revalidate|dynamic)\s*=|unstable_cache\([\s\S]*?revalidate:\s*\d+/;

test("every data page is either request-specific or declares its freshness", () => {
  const frozen = pages(DASHBOARD)
    .filter((p) => {
      const src = readFileSync(p, "utf8");
      return READS_DATA.test(src) && !REQUEST_SPECIFIC.test(src) && !SAYS_HOW_FRESH.test(src);
    })
    .map((p) => relative(ROOT, p).replaceAll("\\", "/"));
  assert.deepEqual(frozen, [], `these would be frozen at build time:\n  ${frozen.join("\n  ")}`);
});

// `revalidate = 60` (and unstable_cache's revalidate) reads as "at most a
// minute old", but Next rebuilds only when someone asks, and answers THAT
// request with the old render. On a console visited a few times a day the first
// view is nearly always stale: on 2026-10-29 the Jobs page left out a job posted
// 30 minutes earlier, and Overview the same way. Data pages render per request.
test("no data page answers with a cached render", () => {
  const cached = pages(DASHBOARD)
    .filter((p) => {
      const src = readFileSync(p, "utf8");
      return READS_DATA.test(src) && /export const revalidate\s*=|unstable_cache\(/.test(src);
    })
    .map((p) => relative(ROOT, p).replaceAll("\\", "/"));
  assert.deepEqual(cached, [], `these serve a stale render on the first visit after a quiet spell:\n  ${cached.join("\n  ")}`);
});
