// Money is stored in WHOLE KES (mpesa.service.ts writes the shilling amount;
// Daraja takes "at least 100 KES"). Twice now a page's local formatter divided
// by 100 as if it were cents: first every Payments page ("KES 500" shown as
// "KES 5.00"), then — found 2026-10-29 — Overview, Revenue, Refunds and
// Trends, which showed KES 68,700 of locked escrow as "KES 687". This guard
// fails the build the next time a page converts "cents" that do not exist.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(fileURLToPath(new URL(".", import.meta.url)), "..");

function sources(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    if (name === "node_modules" || name.startsWith(".")) continue;
    const path = join(dir, name);
    if (statSync(path).isDirectory()) out.push(...sources(path));
    else if (/\.(tsx?|mjs)$/.test(name) && !/\.test\.mjs$/.test(name)) out.push(path);
  }
  return out;
}

test("no page divides a money amount by 100", () => {
  const money = /KES|kes|total_paid|revenue|amount|fee|cents|escrow/;
  const offenders = [];
  for (const file of [...sources(join(root, "app")), ...sources(join(root, "lib")), ...sources(join(root, "components"))]) {
    readFileSync(file, "utf8").split("\n").forEach((line, i) => {
      if (/\/\s*100\b/.test(line) && money.test(line) && !/pct|percent|%/.test(line)) {
        offenders.push(`${relative(root, file)}:${i + 1}: ${line.trim()}`);
      }
    });
  }
  assert.deepEqual(offenders, [], `money treated as cents:\n${offenders.join("\n")}`);
});
