// Seed synthetic OFFER listings for a Discover load test. WRITES PRODUCTION.
//
//   node scripts/feed-loadtest/seed.mjs --run <id> --count 5000 \
//        --i-have-approval-to-write-production
//
// What it writes, and why it is shaped this way:
//   * ONE synthetic author, `loadtest-feed-<run>`: no email, no phone, no FCM
//     token (nothing can be pushed to it), role `user`. Every seeded post hangs
//     off it, so cleanup.mjs removes the run with one predicate.
//   * OFFERS only. Admin alerts flag open REQUESTS nobody has answered; offers
//     exercise the same feed and paging path without flooding that queue.
//   * is_urgent = false, so nothing reaches the urgent banner or its badge.
//   * created_at spread over 90 days, with 10% sharing ONE instant — what a bulk
//     INSERT with a default now() produces, and the case a keyset cursor gets
//     wrong if it orders by created_at alone.
//   * Titles say "[Load test]" and the description says the listing is
//     synthetic and temporary, so a real user who sees one is not misled.
import {
  SUPABASE_URL, serviceHeaders, args, authorFor, requireProductionFlag, count,
} from './lib.mjs';

const a = args();
requireProductionFlag(a);
const run = a.run;
const total = Number(a.count ?? 0);
if (!run || !/^[a-z0-9-]{3,40}$/.test(run) || !(total > 0 && total <= 100000)) {
  console.error('usage: seed.mjs --run <a-z0-9-> --count <1..100000> --i-have-approval-to-write-production');
  process.exit(2);
}
const author = authorFor(run);

const CATEGORIES = ['Plumbing', 'Electrical', 'House Cleaning', 'Gardening', 'Carpentry',
  'Painting', 'Tutoring', 'Moving', 'Photography', 'Catering', 'Hair & Beauty', 'Tailoring'];
const PLACES = [
  ['Westlands, Nairobi', -1.2683, 36.8103], ['Kilimani, Nairobi', -1.2921, 36.7856],
  ['Karen, Nairobi', -1.3197, 36.7073], ['Kasarani, Nairobi', -1.2219, 36.8968],
  ['Nyali, Mombasa', -4.0435, 39.7106], ['Milimani, Kisumu', -0.0917, 34.7680],
  ['Nakuru Town, Nakuru', -0.3031, 36.0800],
];

// Deterministic, so two runs of the same size are comparable.
let state = 0x2f6b1a;
const rand = () => ((state = (state * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);

async function post(path, body, prefer = 'return=minimal') {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    method: 'POST',
    headers: { ...serviceHeaders, 'Content-Type': 'application/json', Prefer: prefer },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`${path} HTTP ${r.status}: ${await r.text()}`);
}

const before = await count('posts', '');
console.log(`[seed] run=${run} author=${author} count=${total} posts_before=${before}`);

await post('users', {
  id: author,
  name: 'Help24 Load Test',
  email: null,
  role: 'user',
  account_type: 'individual',
  bio: `Synthetic account for feed load test ${run}. Removed after the test.`,
}, 'return=minimal,resolution=ignore-duplicates');

const now = Date.now();
const tieInstant = new Date(now - 3 * 86400_000).toISOString();
const BATCH = 500;
const started = performance.now();
for (let offset = 0; offset < total; offset += BATCH) {
  const rows = [];
  for (let i = offset; i < Math.min(total, offset + BATCH); i++) {
    const [location, lat, lng] = PLACES[Math.floor(rand() * PLACES.length)];
    const category = CATEGORIES[Math.floor(rand() * CATEGORIES.length)];
    rows.push({
      title: `[Load test] ${category} #${i + 1}`,
      description: `Synthetic listing created to load-test the Discover feed (run ${run}). ` +
        'It will be removed shortly — please ignore it.',
      category,
      location,
      latitude: +(lat + (rand() - 0.5) * 0.08).toFixed(4),
      longitude: +(lng + (rand() - 0.5) * 0.08).toFixed(4),
      urgency: rand() < 0.5 ? 'flexible' : 'soon',
      price: 500 + Math.floor(rand() * 40) * 250,
      pricing_type: 'task',
      type: 'offer',
      status: 'open',
      difficulty: 'medium',
      is_urgent: false,
      author_user_id: author,
      author_name: 'Help24 Load Test',
      author_temp_id: '',
      attributes_schema_version: 1,
      attributes: { loadtest_run: run },
      created_at: i % 10 === 0
        ? tieInstant
        : new Date(now - Math.floor(rand() * 90 * 86400_000)).toISOString(),
    });
  }
  const t = performance.now();
  await post('posts', rows);
  console.log(`[seed] ${Math.min(total, offset + BATCH)}/${total} +${Math.round(performance.now() - t)}ms`);
}
const seconds = (performance.now() - started) / 1000;
const seeded = await count('posts', `author_user_id=eq.${author}`);
console.log(JSON.stringify({ run, seeded, requested: total, seconds: +seconds.toFixed(1),
  rowsPerSecond: Math.round(seeded / seconds), postsAfter: await count('posts', '') }, null, 2));
process.exit(seeded === total ? 0 : 1);
