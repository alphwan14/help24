// node supabase-auth-emails/build.mjs  (or: npm run emails:build)
//
// Writes html/<key>.html and html/manifest.json from templates.mjs. The output
// is committed so the runbook can point at exact files; lib/auth-emails.test.mjs
// fails if it drifts from the source.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { TEMPLATES, manifest, render } from "./templates.mjs";

const dist = join(dirname(fileURLToPath(import.meta.url)), "html");
mkdirSync(dist, { recursive: true });
for (const t of TEMPLATES) writeFileSync(join(dist, `${t.key}.html`), render(t));
writeFileSync(join(dist, "manifest.json"), JSON.stringify(manifest(), null, 2) + "\n");
console.log(`wrote ${TEMPLATES.length} templates + manifest.json to ${dist}`);
