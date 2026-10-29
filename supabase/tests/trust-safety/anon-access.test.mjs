// Migration 129 — what the publishable key can and cannot do.
//
//   cd supabase/tests/trust-safety && npm run test:anon
//
// Same harness as db.test.mjs: the live-schema replica, plus the two tables it
// lacks (fixtures/129_live_prestate.sql, copied from live), then 129 applied
// twice to prove it re-runs. Each test runs in a rolled-back transaction, as
// the roles PostgREST uses.
import assert from 'node:assert/strict';
import { withDatabase, MIGRATIONS } from './harness.mjs';

const ID = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const U = { alice: 'u_alice', bob: 'u_bob', carol: 'u_carol' };
const POST = ID(1);
const N = { aliceChat: ID(21), aliceApplied: ID(22), bob: ID(23) };
const DENIED = /permission denied/;
const RLS = /row-level security/;

async function seed(db) {
  for (const [id, name] of [[U.alice, 'Alice'], [U.bob, 'Bob'], [U.carol, 'Carol']]) {
    await db.query('INSERT INTO public.users (id, email, name) VALUES ($1, $2, $3)', [id, `${id}@example.com`, name]);
  }
  await db.query(
    `INSERT INTO public.posts (id, title, description, category, location, urgency, price, type, author_temp_id, author_user_id)
     VALUES ($1, 'Fix my sink', 'd', 'Plumbing', 'Nyali', 'flexible', 1500, 'request', 'tmp', $2)`, [POST, U.alice]);
  await db.query('INSERT INTO public.post_images (post_id, image_url) VALUES ($1, $2)', [POST, 'https://example.com/a.jpg']);
  await db.query(
    `INSERT INTO public.applications (post_id, applicant_temp_id, applicant_user_id, message, proposed_price)
     VALUES ($1, 'tmp', $2, 'I can come today', 1200)`, [POST, U.bob]);
  const note = (id, uid, type, body) => db.query(
    'INSERT INTO public.notifications (id, user_id, type, title, body, data) VALUES ($1, $2, $3, $4, $5, $6)',
    [id, uid, type, 'Title', body, JSON.stringify({ post_id: POST })]);
  await note(N.aliceChat, U.alice, 'chat_message', 'Bob: the gate code is 4471');
  await note(N.aliceApplied, U.alice, 'provider_applied', 'Bob applied');
  await note(N.bob, U.bob, 'payment_secured', 'Payment secured');
  await db.query(`INSERT INTO public.providers (name, phone_login, phone_payout) VALUES ('P', '254700000000', '254700000000')`);
  await db.query(
    `INSERT INTO public.messages (sender_user_id, receiver_user_id, content) VALUES ($1, $2, 'hello')`, [U.alice, U.bob]);
}

function ctx(db) {
  async function run(role, uid, sql, params = []) {
    await db.query('SAVEPOINT step');
    try {
      if (role !== 'owner') {
        const claims = { role, ...(uid ? { user_id: uid } : {}) };
        await db.query("SELECT set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims)]);
        await db.query(`SET LOCAL ROLE ${role}`);
      }
      const result = await db.query(sql, params);
      await db.query('RESET ROLE');
      await db.query("SELECT set_config('request.jwt.claims', '', true)");
      await db.query('RELEASE SAVEPOINT step');
      return result;
    } catch (e) {
      await db.query('ROLLBACK TO SAVEPOINT step');
      throw e;
    }
  }
  async function rejects(promise, pattern) {
    try {
      await promise;
    } catch (e) {
      assert.match(e.message, pattern);
      return;
    }
    assert.fail(`expected a failure matching ${pattern}`);
  }
  return {
    rejects,
    owner: (sql, p) => run('owner', null, sql, p),
    svc: (sql, p) => run('service_role', null, sql, p),
    anon: (sql, p) => run('anon', null, sql, p),
    user: (uid) => (sql, p) => run('authenticated', uid, sql, p),
  };
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

// ── notifications ────────────────────────────────────────────────────────────
test('anon cannot read anyone\'s notifications — not even with a user_id filter', async (t) => {
  await t.rejects(t.anon('SELECT body FROM public.notifications'), DENIED);
  await t.rejects(t.anon('SELECT body FROM public.notifications WHERE user_id = $1', [U.alice]), DENIED);
});

test('anon cannot rewrite a notification', async (t) => {
  await t.rejects(t.anon(`UPDATE public.notifications SET body = 'Pay here' WHERE id = $1`, [N.aliceChat]), DENIED);
  assert.equal((await t.owner('SELECT body FROM public.notifications WHERE id = $1', [N.aliceChat])).rows[0].body,
    'Bob: the gate code is 4471');
});

test('a member reads their own notifications and nobody else\'s', async (t) => {
  const mine = await t.user(U.alice)('SELECT id FROM public.notifications ORDER BY id');
  assert.deepEqual(mine.rows.map((r) => r.id), [N.aliceChat, N.aliceApplied]);
  const peek = await t.user(U.bob)('SELECT id FROM public.notifications WHERE user_id = $1', [U.alice]);
  assert.equal(peek.rowCount, 0);
});

test('a member marks their own notification read, and cannot touch someone else\'s', async (t) => {
  const own = await t.user(U.alice)('UPDATE public.notifications SET read = true WHERE id = $1', [N.aliceApplied]);
  assert.equal(own.rowCount, 1);
  const other = await t.user(U.bob)('UPDATE public.notifications SET read = true WHERE id = $1', [N.aliceChat]);
  assert.equal(other.rowCount, 0);
});

test('the backend still writes and reads every notification', async (t) => {
  await t.svc(`INSERT INTO public.notifications (user_id, type, title, body) VALUES ($1, 'request_match', 'T', 'B')`, [U.carol]);
  assert.equal((await t.svc('SELECT count(*)::int AS n FROM public.notifications')).rows[0].n, 4);
});

// ── providers ────────────────────────────────────────────────────────────────
test('providers (payout phone numbers) is backend-only', async (t) => {
  await t.rejects(t.anon('SELECT phone_payout FROM public.providers'), DENIED);
  await t.rejects(t.user(U.alice)('SELECT phone_payout FROM public.providers'), DENIED);
  assert.equal((await t.svc('SELECT count(*)::int AS n FROM public.providers')).rows[0].n, 1);
});

// ── legacy messages ──────────────────────────────────────────────────────────
test('legacy messages: only the two participants, and only in their own name', async (t) => {
  assert.equal((await t.user(U.carol)('SELECT id FROM public.messages')).rowCount, 0);
  assert.equal((await t.user(U.alice)('SELECT id FROM public.messages')).rowCount, 1);
  await t.rejects(t.user(U.carol)(
    `INSERT INTO public.messages (sender_user_id, receiver_user_id, content) VALUES ($1, $2, 'x')`, [U.alice, U.bob]), RLS);
});

// ── posts ────────────────────────────────────────────────────────────────────
test('logged-out browsing still reads posts, images and applicant rows', async (t) => {
  assert.equal((await t.anon('SELECT id FROM public.posts WHERE id = $1', [POST])).rowCount, 1);
  assert.equal((await t.anon('SELECT image_url FROM public.post_images WHERE post_id = $1', [POST])).rowCount, 1);
  // Still open on purpose (cards count applicants from these rows) — see 129's
  // header. This assertion is the reminder that it is a known, staged item.
  assert.equal((await t.anon('SELECT id FROM public.applications WHERE post_id = $1', [POST])).rowCount, 1);
});

test('anon cannot create a post', async (t) => {
  await t.rejects(t.anon(
    `INSERT INTO public.posts (title, description, category, location, urgency, price, type, author_temp_id, author_user_id)
     VALUES ('Spam', 'd', 'Plumbing', 'Nyali', 'flexible', 1, 'offer', 'tmp', $1)`, [U.alice]), DENIED);
});

test('a member posts in their own name and never in someone else\'s', async (t) => {
  const insert = (uid, author) => t.user(uid)(
    `INSERT INTO public.posts (title, description, category, location, urgency, price, type, author_temp_id, author_user_id)
     VALUES ('Tiling', 'd', 'Plumbing', 'Nyali', 'flexible', 100, 'offer', '', $1) RETURNING id`, [author]);
  assert.equal((await insert(U.bob, U.bob)).rowCount, 1);
  await t.rejects(insert(U.bob, U.alice), RLS);
});

// ── post_images ──────────────────────────────────────────────────────────────
test('only a post\'s author adds images to it', async (t) => {
  const add = (runner) => runner('INSERT INTO public.post_images (post_id, image_url) VALUES ($1, $2)', [POST, 'https://example.com/b.jpg']);
  assert.equal((await add(t.user(U.alice))).rowCount, 1);
  await t.rejects(add(t.user(U.bob)), RLS);
  await t.rejects(add(t.anon), DENIED);
});

test('nobody deletes images directly; deleting the post removes them', async (t) => {
  await t.rejects(t.anon('DELETE FROM public.post_images'), DENIED);
  await t.rejects(t.user(U.bob)('DELETE FROM public.post_images WHERE post_id = $1', [POST]), DENIED);
  await t.user(U.alice)('DELETE FROM public.posts WHERE id = $1', [POST]);
  assert.equal((await t.owner('SELECT count(*)::int AS n FROM public.post_images WHERE post_id = $1', [POST])).rows[0].n, 0);
});

// ── applications ─────────────────────────────────────────────────────────────
test('a member applies in their own name only; anon cannot apply', async (t) => {
  const apply = (runner, applicant) => runner(
    `INSERT INTO public.applications (post_id, applicant_temp_id, applicant_user_id, message, proposed_price)
     VALUES ($1, '', $2, 'Available', 900)`, [POST, applicant]);
  assert.equal((await apply(t.user(U.carol), U.carol)).rowCount, 1);
  await t.rejects(apply(t.user(U.carol), U.bob), RLS);
  await t.rejects(apply(t.anon, U.carol), DENIED);
  await t.rejects(t.user(U.bob)(`UPDATE public.applications SET proposed_price = 1 WHERE applicant_user_id = $1`, [U.bob]), DENIED);
});

// ── TRUNCATE is not subject to RLS ───────────────────────────────────────────
test('neither client role can TRUNCATE any table 129 touches', async (t) => {
  const r = await t.owner(`
    SELECT r, tbl FROM unnest(array['anon','authenticated']) r,
      unnest(array['public.notifications','public.providers','public.messages','public.posts','public.post_images','public.applications']) tbl
    WHERE has_table_privilege(r, tbl, 'TRUNCATE')`);
  assert.deepEqual(r.rows, []);
});

// =============================================================================
const only = process.argv[2] ? new RegExp(process.argv[2], 'i') : null;
let passed = 0;
const failures = [];

await withDatabase(async (db) => {
  await seed(db);
  for (const { name, fn } of tests) {
    if (only && !only.test(name)) continue;
    await db.query('BEGIN');
    try {
      await fn(ctx(db));
      passed++;
      console.log(`  ✓ ${name}`);
    } catch (e) {
      failures.push({ name, error: e });
      console.log(`  ✗ ${name}\n      ${e.message.split('\n').join('\n      ')}`);
    } finally {
      await db.query('ROLLBACK');
    }
  }
}, { files: MIGRATIONS, applyTwice: true });

console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) process.exit(1);
