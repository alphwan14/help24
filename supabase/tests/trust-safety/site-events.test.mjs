// First-party website events (migration 137) — database tests.
//
//   cd supabase/tests/trust-safety && npm run test:site-events
//
// The website writes with the publishable key (`anon`) through
// record_site_event(); nobody but the service role reads.
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { MIGRATIONS, withDatabase } from './harness.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const M137 = path.join(here, '../../migrations/137_site_events.sql');
const PROVIDER = 'AbCdEfGhIjKlMnOpQrStUvWx12';
const OTHER = 'ZyXwVuTsRqPoNmLkJiHgFeDc98';

function ctx(db) {
  async function run(role, sql, params = []) {
    await db.query('SAVEPOINT step');
    try {
      if (role !== 'owner') {
        await db.query("SELECT set_config('request.jwt.claims', $1, true)", [JSON.stringify({ role })]);
        await db.query(`SET LOCAL ROLE ${role}`);
      }
      const r = await db.query(sql, params);
      await db.query('RESET ROLE');
      await db.query('RELEASE SAVEPOINT step');
      return r;
    } catch (e) {
      await db.query('ROLLBACK TO SAVEPOINT step');
      throw e;
    }
  }
  const record = (event, o = {}) => run('anon',
    'SELECT public.record_site_event($1,$2,$3,$4,$5,$6,$7,$8) AS kept',
    [event, o.provider ?? null, o.source ?? null, o.platform ?? 'android', o.browser ?? 'chrome', o.version ?? '1.0.9', o.country ?? 'KE', o.path ?? '/p/x'],
  ).then((r) => r.rows[0].kept);
  const rows = async () => (await run('owner', 'SELECT * FROM public.site_events ORDER BY id')).rows;
  const stats = async (days = 30) => (await run('service_role', 'SELECT public.admin_provider_card_stats($1) AS s', [days])).rows[0].s;
  return { run, record, rows, stats };
}

async function rejects(promise, pattern) {
  try { await promise; } catch (e) { assert.match(e.message, pattern); return; }
  assert.fail(`expected a failure matching ${pattern}`);
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test('the website can record a card open for a real member', async (t) => {
  assert.equal(await t.record('provider_card_open', { provider: PROVIDER, source: 'qr', path: `/p/${PROVIDER}` }), true);
  const [r] = await t.rows();
  assert.equal(r.event, 'provider_card_open');
  assert.equal(r.provider_id, PROVIDER);
  assert.equal(r.source, 'qr');
  assert.equal(r.country, 'KE');
});

test('invented providers, unknown events and malformed fields are not kept', async (t) => {
  assert.equal(await t.record('provider_card_open', { provider: 'NotARealMemberButLongEnough1' }), false);
  assert.equal(await t.record('provider_card_open', { provider: "x'; drop table users; --" }), false);
  assert.equal(await t.record('provider_card_open'), false);
  assert.equal(await t.record('page_view'), false);
  assert.equal(await t.record('download_click', { provider: PROVIDER, platform: 'windows phone', browser: '<script>', version: 'abc', country: 'Kenya', path: '/download?ref=x' }), true);
  const rows = await t.rows();
  assert.equal(rows.length, 1);
  assert.deepEqual(
    { provider: rows[0].provider_id, platform: rows[0].platform, browser: rows[0].browser, version: rows[0].app_version, country: rows[0].country, path: rows[0].path },
    { provider: null, platform: null, browser: null, version: null, country: null, path: null },
  );
});

test('clients cannot read or write the table, or read the stats', async (t) => {
  await rejects(t.run('anon', 'SELECT * FROM public.site_events'), /permission denied/);
  await rejects(t.run('anon', `INSERT INTO public.site_events (event) VALUES ('qr_scan')`), /permission denied/);
  await rejects(t.run('authenticated', 'SELECT * FROM public.site_events'), /permission denied/);
  await rejects(t.run('anon', 'SELECT public.admin_provider_card_stats(30)'), /permission denied/);
});

test('the stats answer "is the card being shared?"', async (t) => {
  for (let i = 0; i < 3; i++) await t.record('provider_card_open', { provider: PROVIDER, source: 'qr' });
  await t.record('provider_card_open', { provider: PROVIDER, source: 'link', platform: 'desktop' });
  await t.record('provider_card_open', { provider: OTHER, source: 'link' });
  await t.record('provider_card_open_app', { provider: PROVIDER });
  await t.record('download_click');
  await t.run('owner', `INSERT INTO public.site_events (event, provider_id, source, created_at) VALUES ('provider_card_open', $1, 'qr', now() - interval '40 days')`, [OTHER]);

  const s = await t.stats(30);
  assert.equal(s.opens, 5);
  assert.equal(s.opens_qr, 3);
  assert.equal(s.opens_link, 2);
  assert.equal(s.open_app_taps, 1);
  assert.equal(s.download_clicks, 1);
  assert.equal(s.providers_shared, 2);
  assert.deepEqual(s.by_platform, { android: 4, desktop: 1 });
  assert.equal(s.top_providers[0].provider_id, PROVIDER);
  assert.equal(s.top_providers[0].name, 'Card Provider');
  assert.equal(s.top_providers[0].opens, 4);
  assert.equal(s.top_providers[0].qr, 3);
  assert.equal(s.top_providers[0].open_app, 1);
  assert.equal((await t.stats(60)).opens, 6);
});

const only = process.argv[2] ? new RegExp(process.argv[2], 'i') : null;
let passed = 0;
const failures = [];
await withDatabase(async (db) => {
  await db.query(`INSERT INTO public.users (id, email, name, profession) VALUES ($1, 'p@example.com', 'Card Provider', 'Nanny'), ($2, 'o@example.com', 'Other', 'Tutor')`, [PROVIDER, OTHER]);
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
}, { files: [...MIGRATIONS, M137, M137] });
console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) process.exit(1);
