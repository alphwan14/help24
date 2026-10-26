// Walk Discover to the end exactly as the app does, and compare what is
// reachable with what is in the table. READ-ONLY.
//
//   node scripts/feed-loadtest/walk.mjs [--scope all|requests|offers|jobs] [--user <uid>]
//
// Ranked head: GET /feed?page=n until has_more is false. Tail: keyset probes
// over (created_at, id) with the app's publishable key, hydrating only unseen
// ids. Mirrors mobile-app/lib/services/feed_pager.dart step for step.
import {
  API, SUPABASE_URL, appHeaders, args, count, ELIGIBLE, TYPES, percentiles,
} from './lib.mjs';

const PAGE = 20, PROBE = 200, MAX_STEPS = 8;
const FEED_ROW_SELECT =
  '*, users:public_profiles!author_user_id(name, profile_image, avatar_url, has_phone), ' +
  'post_images(image_url), ' +
  'applications(*, users:public_profiles!applicant_user_id(name, profile_image, avatar_url, profession))';

export async function walk({ scope = 'all', user = null, quiet = false } = {}) {
  const types = TYPES[scope];
  const base = `${ELIGIBLE}&type=in.(${types.join(',')})`;
  const t = { ranked: [], probe: [], hydrate: [] };
  const errors = { ranked429: 0, rankedOther: 0 };
  async function timed(bucket, url, headers = {}) {
    const start = performance.now();
    const r = await fetch(url, { headers });
    t[bucket].push(performance.now() - start);
    return r;
  }

  const shown = [];
  const seen = new Set();
  let page = 0, candidateCount = null, inHead = true;
  while (inHead) {
    const r = await timed('ranked',
      `${API}/feed?scope=${scope}&page=${page}${user ? `&user_id=${user}` : ''}`);
    if (!r.ok) {
      // Same as the app: a later ranked page failing hands over to the tail.
      if (r.status === 429) errors.ranked429++; else errors.rankedOther++;
      if (page === 0) throw new Error(`first page HTTP ${r.status}`);
      break;
    }
    const body = await r.json();
    candidateCount = body.candidate_count;
    for (const it of body.items) if (!seen.has(it.post.id)) { seen.add(it.post.id); shown.push(it.post.id); }
    inHead = body.has_more && body.items.length > 0;
    page++;
  }
  const fromHead = shown.length;

  // Probed-but-unserved keys carry over between pages, as in FeedCursor.buffered.
  let after = null, buffer = [], ended = false, exhausted = false, tailPages = 0;
  while (!exhausted) {
    const taken = [];
    let steps = 0;
    while (taken.length < PAGE) {
      if (buffer.length === 0) {
        if (ended || steps >= MAX_STEPS) break;
        steps++;
        let url = `${SUPABASE_URL}/rest/v1/posts?select=id,created_at&${base}` +
          `&order=created_at.desc,id.desc&limit=${PROBE}`;
        if (after) {
          const at = `"${after.created_at}"`;
          url += `&or=${encodeURIComponent(`(created_at.lt.${at},and(created_at.eq.${at},id.lt."${after.id}"))`)}`;
        }
        const r = await timed('probe', url, appHeaders);
        if (!r.ok) throw new Error(`probe HTTP ${r.status}: ${await r.text()}`);
        buffer = await r.json();
        if (buffer.length) after = buffer.at(-1);
        if (buffer.length < PROBE) ended = true;
        continue;
      }
      const key = buffer.shift();
      if (!seen.has(key.id) && !taken.includes(key.id)) taken.push(key.id);
    }
    exhausted = ended && buffer.length === 0;
    if (taken.length) {
      const r = await timed('hydrate', `${SUPABASE_URL}/rest/v1/posts?select=` +
        `${encodeURIComponent(FEED_ROW_SELECT)}&id=in.(${taken.join(',')})&archived_at=is.null`, appHeaders);
      if (!r.ok) throw new Error(`hydrate HTTP ${r.status}: ${await r.text()}`);
      const rows = await r.json();
      const got = new Set(rows.map((x) => x.id));
      for (const id of taken) if (got.has(id) && !seen.has(id)) { seen.add(id); shown.push(id); }
      tailPages++;
    }
  }

  const result = {
    scope,
    reachable: shown.length,
    fromRankedHead: fromHead,
    fromTail: shown.length - fromHead,
    engineCandidateCount: candidateCount,
    rankedPages: page,
    tailPages,
    duplicates: shown.length - new Set(shown).size,
    errors,
    latencyMs: { ranked: percentiles(t.ranked), probe: percentiles(t.probe), hydrate: percentiles(t.hydrate) },
  };
  if (!quiet) console.log(JSON.stringify(result, null, 2));
  // Raw samples for bench.mjs to aggregate; non-enumerable so they never print.
  Object.defineProperty(result, '_samples', { value: t });
  return result;
}

if (process.argv[1]?.endsWith('walk.mjs')) {
  const a = args();
  const scope = a.scope ?? 'all';
  const inTable = await count('posts', `${ELIGIBLE}&type=in.(${TYPES[scope].join(',')})`);
  const r = await walk({ scope, user: a.user ?? null, quiet: true });
  console.log(JSON.stringify({ databaseEligible: inTable, ...r, match: r.reachable === inTable && r.duplicates === 0 }, null, 2));
  process.exit(r.reachable === inTable && r.duplicates === 0 ? 0 : 1);
}
