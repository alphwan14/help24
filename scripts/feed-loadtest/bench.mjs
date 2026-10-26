// Concurrent readers scrolling Discover. READ-ONLY.
//
//   node scripts/feed-loadtest/bench.mjs [--readers 10] [--rounds 3] [--scope all]
//
// Each reader walks the whole feed (ranked head + tail) exactly as the app
// does; `--readers` of them run at once, `--rounds` times. Reports per-step
// latency percentiles across every request, plus completeness per walk — a
// walk that misses or repeats a post is a failure regardless of speed.
//
// One machine is one IP: the backend's per-IP token bucket (900 burst) applies
// to the ranked head. A throttled ranked page is counted in `ranked429` and the
// walk continues in the tail, as the app does.
import { args, count, ELIGIBLE, TYPES, percentiles } from './lib.mjs';
import { walk } from './walk.mjs';

const a = args();
const readers = Number(a.readers ?? 10);
const rounds = Number(a.rounds ?? 3);
const scope = a.scope ?? 'all';

const inTable = await count('posts', `${ELIGIBLE}&type=in.(${TYPES[scope].join(',')})`);
console.log(`[bench] scope=${scope} eligible=${inTable} readers=${readers} rounds=${rounds}`);

const all = { ranked: [], probe: [], hydrate: [] };
const walls = [];
let incomplete = 0, throttled = 0, rankedErrors = 0;

for (let round = 1; round <= rounds; round++) {
  const started = performance.now();
  const results = await Promise.all(Array.from({ length: readers }, () =>
    walk({ scope, quiet: true }).catch((e) => ({ error: e.message }))));
  walls.push(performance.now() - started);
  for (const r of results) {
    if (r.error) { incomplete++; console.log(`[bench] walk failed: ${r.error}`); continue; }
    if (r.reachable !== inTable || r.duplicates !== 0) incomplete++;
    throttled += r.errors.ranked429;
    rankedErrors += r.errors.rankedOther;
    for (const k of Object.keys(all)) all[k].push(...(r._samples?.[k] ?? []));
  }
  const ok = results.filter((r) => !r.error);
  console.log(`[bench] round ${round}: ${Math.round(walls.at(-1))}ms wall, ` +
    `reachable=${ok.map((r) => r.reachable).join(',')} ` +
    `ranked p95=${ok.map((r) => r.latencyMs.ranked.p95).join(',')}ms ` +
    `probe p95=${ok.map((r) => r.latencyMs.probe.p95).join(',')}ms ` +
    `hydrate p95=${ok.map((r) => r.latencyMs.hydrate.p95 ?? '-').join(',')}ms`);
}

console.log(JSON.stringify({
  scope, eligible: inTable, readers, rounds,
  walks: readers * rounds,
  incompleteWalks: incomplete,
  ranked429: throttled,
  rankedOtherErrors: rankedErrors,
  wallMsPerRound: percentiles(walls),
  latencyMs: {
    rankedPage: percentiles(all.ranked),
    tailProbe: percentiles(all.probe),
    tailHydrate: percentiles(all.hydrate),
  },
}, null, 2));
process.exit(incomplete === 0 ? 0 : 1);
