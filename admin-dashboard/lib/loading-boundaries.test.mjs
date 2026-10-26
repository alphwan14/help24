// node --test lib/loading-boundaries.test.mjs
//
// Every dashboard section must have a route-level loading.tsx. Without one, a
// click keeps the old page on screen until the server has finished the new one
// (0.8–1.9 s measured on production), and Next has nothing to prefetch for a
// dynamic route. See components/RouteSkeleton.tsx for why it is one boundary
// per SECTION rather than one for /dashboard.
import assert from "node:assert/strict";
import { existsSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const DASHBOARD = resolve(dirname(fileURLToPath(import.meta.url)), "..", "app", "dashboard");

// Folders whose only page is a redirect elsewhere: there is nothing to wait for.
const REDIRECT_ONLY = new Set(["offers", "requests"]);

test("every dashboard section has a loading boundary", () => {
  const sections = readdirSync(DASHBOARD).filter(
    (name) => statSync(join(DASHBOARD, name)).isDirectory() && !REDIRECT_ONLY.has(name),
  );
  assert.ok(sections.length >= 9, `expected the dashboard sections, found ${sections.join(", ")}`);

  const missing = sections.filter((name) => !existsSync(join(DASHBOARD, name, "loading.tsx")));
  assert.deepEqual(missing, [], `sections without app/dashboard/<section>/loading.tsx: ${missing.join(", ")}`);
});

test("dynamic detail routes have their own boundary", () => {
  // Under the section boundary these would flash a LIST skeleton for a detail page.
  for (const route of ["disputes/[id]", "promotion/[id]", "marketplace/requests/[id]", "trust-safety/reports/[id]", "trust-safety/users/[id]", "users/[id]", "partners/[id]"]) {
    assert.ok(existsSync(join(DASHBOARD, route, "loading.tsx")), `${route} has no loading.tsx`);
  }
});
