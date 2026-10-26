// Remove everything one seed run created. WRITES PRODUCTION.
//
//   node scripts/feed-loadtest/cleanup.mjs --run <id> --i-have-approval-to-write-production
//
// Deletes only rows owned by the synthetic author `loadtest-feed-<run>` (posts
// first, then anything hanging off them that a stray tap could have created,
// then the author), and verifies each count reaches zero.
import {
  SUPABASE_URL, serviceHeaders, args, authorFor, requireProductionFlag, count,
} from './lib.mjs';

const a = args();
requireProductionFlag(a);
if (!a.run || !/^[a-z0-9-]{3,40}$/.test(a.run)) {
  console.error('usage: cleanup.mjs --run <id> --i-have-approval-to-write-production');
  process.exit(2);
}
const author = authorFor(a.run);

async function del(path) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    method: 'DELETE',
    headers: { ...serviceHeaders, Prefer: 'return=minimal' },
  });
  if (!r.ok) throw new Error(`DELETE ${path} HTTP ${r.status}: ${await r.text()}`);
}

const posts = await count('posts', `author_user_id=eq.${author}`);
console.log(`[cleanup] run=${a.run} author=${author} posts=${posts}`);

// Post deletes go in id batches: one DELETE over tens of thousands of rows with
// cascading children is one long transaction holding locks on a live table.
for (;;) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/posts?select=id&author_user_id=eq.${author}&limit=500`,
    { headers: serviceHeaders });
  const ids = (await r.json()).map((x) => x.id);
  if (ids.length === 0) break;
  // A device scrolling the seeded feed records impressions (user_interactions)
  // against the synthetic posts — those are ranking signals on a REAL account.
  for (const path of ['applications?post_id', 'post_images?post_id',
    'saved_items?item_id', 'user_interactions?post_id']) {
    const table = path.split('?')[0];
    await del(`${path}=in.(${ids.join(',')})`).catch((e) =>
      console.log(`[cleanup] ${table}: ${e.message.slice(0, 120)} (skipped)`));
  }
  await del(`posts?id=in.(${ids.join(',')})`);
  console.log(`[cleanup] deleted ${ids.length} posts`);
}
await del(`users?id=eq.${author}`);

const left = { posts: await count('posts', `author_user_id=eq.${author}`),
  users: await count('users', `id=eq.${author}`) };
console.log(JSON.stringify({ run: a.run, left, postsNow: await count('posts', '') }, null, 2));
process.exit(left.posts === 0 && left.users === 0 ? 0 : 1);
