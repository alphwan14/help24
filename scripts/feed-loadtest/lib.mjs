// Shared plumbing for the Discover feed load test. See README.md.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

/** KEY=value pairs from backend/.env — values are never printed. */
function readEnv() {
  const env = {};
  for (const line of readFileSync(join(root, 'backend', '.env'), 'utf8').split(/\r?\n/)) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
    // Trailing `# comment` is how this file documents where each key lives.
    if (m) env[m[1]] = m[2].replace(/\s+#.*$/, '').trim().replace(/^["']|["']$/g, '');
  }
  return env;
}

const env = readEnv();
export const SUPABASE_URL = env.SUPABASE_URL;
export const SERVICE_KEY = env.SUPABASE_SERVICE_ROLE_KEY;
/** The key that ships in the APK — the tail is read with exactly what the app has. */
export const PUBLISHABLE_KEY = readFileSync(join(root, 'mobile-app', 'lib', 'main.dart'), 'utf8')
  .match(/sb_publishable_[A-Za-z0-9_-]+/)[0];
export const API = process.env.HELP24_API ?? 'https://help24-backend.onrender.com';

/** The synthetic author every seeded post belongs to — the cleanup key. */
export const authorFor = (run) => `loadtest-feed-${run}`;

export const serviceHeaders = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` };
export const appHeaders = { apikey: PUBLISHABLE_KEY, Authorization: `Bearer ${PUBLISHABLE_KEY}` };

export function args() {
  const out = {};
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith('--')) continue;
    const key = argv[i].slice(2);
    out[key] = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
  }
  return out;
}

/** Writes refuse to run unless the operator says, in so many words, where. */
export function requireProductionFlag(a) {
  if (a['i-have-approval-to-write-production'] !== true) {
    console.error('Refusing: this writes to the PRODUCTION database. Re-run with\n' +
      '  --i-have-approval-to-write-production\nonly after the change was approved.');
    process.exit(2);
  }
}

/** Exact count of rows matching a PostgREST filter string. */
export async function count(table, filter) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${table}?select=id&${filter}`, {
    headers: { ...serviceHeaders, Prefer: 'count=exact', Range: '0-0' },
  });
  if (!r.ok) throw new Error(`count ${table} HTTP ${r.status}: ${await r.text()}`);
  return Number(r.headers.get('content-range').split('/')[1]);
}

export const ELIGIBLE = 'archived_at=is.null&status=in.(open)';
export const TYPES = { all: ['request', 'offer'], requests: ['request'], offers: ['offer'], jobs: ['job'] };

export function percentiles(samples) {
  if (samples.length === 0) return { n: 0 };
  const s = [...samples].sort((a, b) => a - b);
  const at = (p) => Math.round(s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]);
  return { n: s.length, p50: at(50), p95: at(95), p99: at(99), max: Math.round(s[s.length - 1]) };
}
