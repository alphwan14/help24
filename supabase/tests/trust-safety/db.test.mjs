// Trust & Safety — database tests.
//
//   cd supabase/tests/trust-safety && npm install && npm test
//
// Every test runs inside a transaction that is rolled back, against a local
// PostgreSQL 17 carrying a replica of the LIVE schema (replica_schema.sql)
// with migrations 114–116 applied. Roles are switched exactly the way
// PostgREST does it — SET ROLE plus request.jwt.claims — so `anon`,
// `authenticated` and `service_role` are exercised against the real grants,
// policies and triggers.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { withDatabase } from './harness.mjs';

const taxonomy = JSON.parse(fs.readFileSync(new URL('./report_taxonomy.json', import.meta.url), 'utf8'));

const ID = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

// ── Fixture identities ───────────────────────────────────────────────────────
const U = {
  alice: 'u_alice', bob: 'u_bob', carol: 'u_carol', dave: 'u_dave',
  erin: 'u_erin', frank: 'u_frank', grace: 'u_grace', adminPerson: 'u_admin_person',
};
const A = { support: ID(901), senior: ID(902), super: ID(903), inactive: ID(904) };
const P = {
  aliceRequest: ID(1), bobOffer: ID(2), bobOffer2: ID(3), bobAssigned: ID(4), aliceJob: ID(5),
  bobExtra: [ID(11), ID(12), ID(13), ID(14), ID(15), ID(16)],
};
const APP_BOB = ID(101);
const CHAT_AB = ID(201);
const CHAT_CD = ID(202);
const MSG_BOB = ID(301);
const MSG_ALICE = ID(302);
const MSG_CAROL = ID(303);

async function seed(db) {
  const users = [
    [U.alice, 'alice@example.com', 'Alice'], [U.bob, 'bob@example.com', 'Bob'],
    [U.carol, 'carol@example.com', 'Carol'], [U.dave, 'dave@example.com', 'Dave'],
    [U.erin, 'erin@example.com', 'Erin'], [U.frank, 'frank@example.com', 'Frank'],
    [U.grace, 'grace@example.com', 'Grace'], [U.adminPerson, 'super@help24.test', 'Super Admin'],
  ];
  for (let i = 0; i < 12; i++) users.push([`u_t${String(i).padStart(2, '0')}`, `t${i}@example.com`, `Target ${i}`]);
  for (const [id, email, name] of users) {
    await db.query('INSERT INTO public.users (id, email, name) VALUES ($1, $2, $3)', [id, email, name]);
  }
  const admins = [
    [A.support, 'support@help24.test', 'support_agent', true],
    [A.senior, 'senior@help24.test', 'senior_admin', true],
    [A.super, 'super@help24.test', 'super_admin', true],
    [A.inactive, 'gone@help24.test', 'senior_admin', false],
  ];
  for (const [id, email, role, active] of admins) {
    await db.query(
      'INSERT INTO public.admin_users (id, email, name, role, token_hash, active) VALUES ($1,$2,$2,$3,$5,$4)',
      [id, email, role, active, `hash-${id}`],
    );
  }
  const post = (id, author, type, status = 'open', title = 'A listing') => db.query(
    `INSERT INTO public.posts (id, title, description, category, location, urgency, price, type,
       author_temp_id, author_user_id, status, employment_type, selected_provider_id)
     VALUES ($1, $2, 'Full description', 'Plumbing', 'Nyali', 'flexible', 1500, $3, 'tmp', $4, $5,
       CASE WHEN $3 = 'job' THEN 'full_time' END, CASE WHEN $5 = 'assigned' THEN 'u_carol' END)`,
    [id, title, type, author, status],
  );
  await post(P.aliceRequest, U.alice, 'request', 'open', 'Fix my sink');
  await post(P.bobOffer, U.bob, 'offer', 'open', 'Cheap plumbing — pay upfront via my number');
  await post(P.bobOffer2, U.bob, 'offer', 'open', 'Tiling');
  await post(P.bobAssigned, U.bob, 'request', 'assigned', 'Paint my wall');
  await post(P.aliceJob, U.alice, 'job', 'open', 'Receptionist');
  for (const id of P.bobExtra) await post(id, U.bob, 'offer', 'open', 'Extra');
  await db.query(
    `INSERT INTO public.applications (id, post_id, applicant_temp_id, applicant_user_id, message, proposed_price)
     VALUES ($1, $2, 'tmp', $3, 'Pay me on 0712 outside Help24', 1200)`,
    [APP_BOB, P.aliceRequest, U.bob],
  );
  await db.query('INSERT INTO public.chats (id, user1, user2, post_id) VALUES ($1, $2, $3, $4)', [CHAT_AB, U.alice, U.bob, P.aliceRequest]);
  await db.query('INSERT INTO public.chats (id, user1, user2) VALUES ($1, $2, $3)', [CHAT_CD, U.carol, U.dave]);
  await db.query('INSERT INTO public.chat_messages (id, chat_id, sender_id, content) VALUES ($1, $2, $3, $4)', [MSG_BOB, CHAT_AB, U.bob, 'Send the money to my personal number or else']);
  await db.query('INSERT INTO public.chat_messages (id, chat_id, sender_id, content) VALUES ($1, $2, $3, $4)', [MSG_ALICE, CHAT_AB, U.alice, 'Hi']);
  await db.query('INSERT INTO public.chat_messages (id, chat_id, sender_id, content) VALUES ($1, $2, $3, $4)', [MSG_CAROL, CHAT_CD, U.carol, 'Hello Dave']);
}

// ── Test plumbing ────────────────────────────────────────────────────────────
function ctx(db) {
  // Run one statement as a role, inside a savepoint so a refusal does not
  // poison the test's transaction.
  async function run(role, uid, sql, params = []) {
    await db.query('SAVEPOINT step');
    try {
      if (role === 'owner') {
        await db.query("SELECT set_config('request.jwt.claims', '', true)");
      } else {
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

  const owner = (sql, params) => run('owner', null, sql, params);
  const svc = (sql, params) => run('service_role', null, sql, params);
  const user = (uid) => (sql, params) => run('authenticated', uid, sql, params);
  const anon = (sql, params) => run('anon', null, sql, params);

  async function rejects(promise, pattern) {
    try {
      await promise;
    } catch (e) {
      assert.match(e.message, pattern);
      return e;
    }
    assert.fail(`expected a failure matching ${pattern}`);
  }

  // The legacy / direct shape the shipped chat sheet sends (migration 084).
  const legacyReport = (uid, fields) => {
    const cols = Object.keys(fields);
    const sql = `INSERT INTO public.user_reports (${cols.join(', ')}) VALUES (${cols.map((_, i) => `$${i + 1}`).join(', ')})`;
    return user(uid)(sql, Object.values(fields));
  };
  // The backend's shape (service_role).
  const apiReport = async (fields) => {
    const row = { source: 'api', ...fields };
    const cols = Object.keys(row);
    const sql = `INSERT INTO public.user_reports (${cols.join(', ')}) VALUES (${cols.map((_, i) => `$${i + 1}`).join(', ')}) RETURNING *`;
    return (await svc(sql, Object.values(row).map((v) => (v !== null && typeof v === 'object' ? JSON.stringify(v) : v)))).rows[0];
  };
  const lastReport = async (reporter) => (await owner(
    'SELECT * FROM public.user_reports WHERE reporter_id = $1 ORDER BY created_at DESC, id DESC LIMIT 1', [reporter])).rows[0];

  const sanction = async (o) => (await svc(
    'SELECT public.moderation_apply_sanction($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r',
    [o.admin ?? A.super, o.user, o.kind, o.reason ?? 'Repeated scam reports after review', o.note ?? null,
      o.endsAt ?? null, o.report ?? null, o.resolve ?? false, o.hide ?? false, o.requestId ?? null],
  )).rows[0].r;
  const lift = async (o) => (await svc(
    'SELECT public.moderation_lift_restriction($1,$2,$3,$4,$5) AS r',
    [o.admin ?? A.super, o.restriction, o.reason ?? 'Appeal upheld after review', o.note ?? null, null],
  )).rows[0].r;
  const resolve = async (o) => (await svc(
    'SELECT public.moderation_resolve_report($1,$2,$3,$4,$5,$6) AS r',
    [o.admin ?? A.support, o.report, o.outcome, o.reason ?? 'Reviewed the evidence', o.note ?? null, null],
  )).rows[0].r;
  const triage = async (o) => (await svc(
    'SELECT public.moderation_update_report($1,$2,$3,$4,$5,$6,$7,$8) AS r',
    [o.admin ?? A.support, o.report, o.status ?? null, o.severity ?? null, o.assignTo ?? null, o.unassign ?? false, o.reason ?? null, null],
  )).rows[0].r;
  const content = async (o) => (await svc(
    'SELECT public.moderation_set_content_state($1,$2,$3,$4,$5,$6,$7,$8) AS r',
    [o.admin ?? A.support, o.type, o.id, o.action, o.reason ?? 'Misleading payment instructions', o.note ?? null, o.report ?? null, null],
  )).rows[0].r;
  const denial = async (uid, cap) => (await svc('SELECT public.moderation_denial($1, $2) AS d', [uid, cap])).rows[0].d;
  const statusOf = async (uid) => (await user(uid)('SELECT public.my_account_status() AS s')).rows[0].s;
  const days = (n) => new Date(Date.now() + n * 86_400_000).toISOString();

  const insertPostAs = (runner, id, author, type = 'offer') => runner(
    `INSERT INTO public.posts (id, title, description, category, location, urgency, price, type, author_temp_id, author_user_id, employment_type)
     VALUES ($1, 'New', 'd', 'Plumbing', 'Nyali', 'flexible', 100, $2, 'tmp', $3, CASE WHEN $2 = 'job' THEN 'full_time' END)`,
    [id, type, author]);

  return {
    db, run, owner, svc, user, anon, rejects, legacyReport, apiReport, lastReport,
    sanction, lift, resolve, triage, content, denial, statusOf, days, insertPostAs,
  };
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

// =============================================================================
// Migrations
// =============================================================================

test('taxonomy: moderation_report_categories matches report_taxonomy.json', async ({ svc }) => {
  for (const [target, expected] of Object.entries(taxonomy.by_target)) {
    const { rows } = await svc('SELECT public.moderation_report_categories($1) AS c', [target]);
    assert.deepEqual(rows[0].c, expected, `categories for ${target}`);
  }
  const { rows } = await svc('SELECT public.moderation_capabilities() AS c');
  assert.deepEqual(rows[0].c, taxonomy.capabilities);
});

test('taxonomy: the reason CHECK accepts exactly the shared categories', async ({ owner }) => {
  const { rows } = await owner(`SELECT pg_get_constraintdef(oid) AS d FROM pg_constraint WHERE conname = 'user_reports_reason_check'`);
  for (const c of taxonomy.categories) assert.match(rows[0].d, new RegExp(`'${c}'`));
  assert.equal((rows[0].d.match(/'[a-z_]+'::text/g) ?? []).length, taxonomy.categories.length);
});

test('indexes exist for the report queue queries', async ({ owner }) => {
  const { rows } = await owner(`SELECT indexname FROM pg_indexes WHERE tablename = 'user_reports'`);
  const names = rows.map((r) => r.indexname);
  for (const n of ['user_reports_one_open_per_target', 'idx_user_reports_reporter', 'idx_user_reports_target',
    'idx_user_reports_open_severity', 'idx_user_reports_open_assignee', 'idx_user_reports_reason',
    'idx_user_reports_status_created', 'idx_user_reports_reported_user']) {
    assert.ok(names.includes(n), `missing index ${n}`);
  }
});

test('severity_rank orders the queue most-serious-first', async (t) => {
  await t.apiReport({ reporter_id: U.alice, target_type: 'post', target_id: P.bobOffer, reason: 'spam' });
  await t.apiReport({ reporter_id: U.dave, target_type: 'message', target_id: MSG_CAROL, reason: 'threats' });
  const { rows } = await t.svc(`SELECT severity, severity_rank FROM public.user_reports
    WHERE status IN ('new','under_review','action_required') ORDER BY severity_rank DESC, created_at`);
  assert.deepEqual(rows.map((r) => [r.severity, Number(r.severity_rank)]), [['high', 3], ['low', 1]]);
});

test('evidence FKs are RESTRICT, not CASCADE', async ({ owner }) => {
  const { rows } = await owner(`SELECT conname, pg_get_constraintdef(oid) AS d FROM pg_constraint
    WHERE conrelid IN ('public.user_reports'::regclass, 'public.account_restrictions'::regclass, 'public.moderation_actions'::regclass)
      AND contype = 'f'`);
  assert.ok(rows.length >= 9);
  for (const r of rows) assert.match(r.d, /ON DELETE RESTRICT/, r.conname);
});

// =============================================================================
// Filing reports — the direct (shipped-app) door
// =============================================================================

test('1/3: a user can report another user (084 shape) and the row is normalised', async (t) => {
  await t.legacyReport(U.alice, { reporter_id: U.alice, reported_user_id: U.bob, reason: 'harassment', details: '  rude  ' });
  const r = await t.lastReport(U.alice);
  assert.equal(r.status, 'new');
  assert.equal(r.target_type, 'user');
  assert.equal(r.target_id, U.bob);
  assert.equal(r.source, 'app_direct');
  assert.equal(r.details, 'rude');
  assert.equal(r.severity, 'medium');
  assert.equal(r.target_snapshot.name, 'Bob');
});

test('the direct door cannot set triage fields or attach evidence', async (t) => {
  await t.legacyReport(U.alice, {
    reporter_id: U.alice, reported_user_id: U.bob, reason: 'spam', status: 'dismissed', severity: 'critical',
    assigned_admin_id: A.super, resolution: 'dismissed', evidence: JSON.stringify([{ path: 'x' }]),
  });
  const r = await t.lastReport(U.alice);
  assert.equal(r.status, 'new');
  assert.equal(r.severity, 'low');
  assert.equal(r.assigned_admin_id, null);
  assert.equal(r.resolution, null);
  assert.deepEqual(r.evidence, []);
});

test('4: nobody can report themselves', async (t) => {
  await t.rejects(t.legacyReport(U.alice, { reporter_id: U.alice, reported_user_id: U.alice, reason: 'spam' }), /HELP24_REPORT_SELF/);
  await t.rejects(t.apiReport({ reporter_id: U.bob, target_type: 'post', target_id: P.bobOffer, reason: 'spam' }), /HELP24_REPORT_SELF/);
});

test('a user cannot file a report as someone else (RLS pins reporter_id to the JWT)', async (t) => {
  await t.rejects(t.legacyReport(U.alice, { reporter_id: U.carol, reported_user_id: U.bob, reason: 'spam' }), /row-level security/);
});

test('anon cannot file a report at all', async (t) => {
  await t.rejects(t.anon(`INSERT INTO public.user_reports (reporter_id, reported_user_id, reason) VALUES ($1, $2, 'spam')`, [U.alice, U.bob]), /permission denied/);
});

test('21: authenticated cannot read, change or delete reports', async (t) => {
  await t.legacyReport(U.alice, { reporter_id: U.alice, reported_user_id: U.bob, reason: 'spam' });
  await t.rejects(t.user(U.alice)('SELECT * FROM public.user_reports'), /permission denied/);
  await t.rejects(t.user(U.bob)(`UPDATE public.user_reports SET status = 'dismissed'`), /permission denied/);
  await t.rejects(t.user(U.alice)('DELETE FROM public.user_reports'), /permission denied/);
});

test('a message can only be reported by someone in that conversation', async (t) => {
  await t.rejects(t.legacyReport(U.carol, { reporter_id: U.carol, reported_user_id: U.bob, reason: 'harassment', message_id: MSG_BOB }), /HELP24_REPORT_NOT_PARTICIPANT/);
  await t.legacyReport(U.alice, { reporter_id: U.alice, reported_user_id: U.bob, reason: 'threats', message_id: MSG_BOB, chat_id: CHAT_AB });
  const r = await t.lastReport(U.alice);
  assert.equal(r.target_type, 'message');
  assert.equal(r.target_snapshot.content, 'Send the money to my personal number or else');
  assert.equal(r.severity, 'high');
});

test('the reported person is derived from the target, and a mismatch is refused', async (t) => {
  await t.rejects(t.legacyReport(U.alice, { reporter_id: U.alice, reported_user_id: U.carol, reason: 'harassment', message_id: MSG_BOB }), /HELP24_REPORT_INVALID_TARGET/);
});

test('listing context is kept only when it involves one of the two people; message context is derived', async (t) => {
  const related = await t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: U.bob, reason: 'harassment', post_id: P.bobOffer });
  assert.equal(related.post_id, P.bobOffer);
  const answered = await t.apiReport({ reporter_id: U.carol, target_type: 'user', target_id: U.bob, reason: 'harassment', post_id: P.aliceRequest });
  assert.equal(answered.post_id, P.aliceRequest, 'Bob applied to it, so it involves him');
  const unrelated = await t.apiReport({ reporter_id: U.dave, target_type: 'user', target_id: U.carol, reason: 'harassment', post_id: P.aliceJob });
  assert.equal(unrelated.post_id, null);
  const msg = await t.apiReport({ reporter_id: U.alice, target_type: 'message', target_id: MSG_BOB, reason: 'threats', post_id: P.aliceJob });
  assert.equal(msg.post_id, P.aliceRequest, 'derived from the conversation, not the client');
});

test('a chat-context report requires both people to be in the chat', async (t) => {
  await t.rejects(t.legacyReport(U.alice, { reporter_id: U.alice, reported_user_id: U.carol, reason: 'harassment', chat_id: CHAT_AB }), /HELP24_REPORT_NOT_PARTICIPANT/);
});

// =============================================================================
// Filing reports — the API door (service_role)
// =============================================================================

test('1: a Request can be reported; the listing is snapshotted', async (t) => {
  const r = await t.apiReport({ reporter_id: U.bob, target_type: 'post', target_id: P.aliceRequest, reason: 'misleading_listing', details: 'Not real' });
  assert.equal(r.reported_user_id, U.alice);
  assert.equal(r.post_id, P.aliceRequest);
  assert.equal(r.target_snapshot.title, 'Fix my sink');
  assert.equal(r.target_snapshot.type, 'request');
  assert.equal(r.source, 'api');
});

test('2: an Offer can be reported', async (t) => {
  const r = await t.apiReport({ reporter_id: U.alice, target_type: 'post', target_id: P.bobOffer, reason: 'scam_or_fraud' });
  assert.equal(r.reported_user_id, U.bob);
  assert.equal(r.target_snapshot.type, 'offer');
  assert.equal(r.severity, 'high');
});

test('an application can be reported, but only by the listing owner', async (t) => {
  await t.rejects(t.apiReport({ reporter_id: U.carol, target_type: 'application', target_id: APP_BOB, reason: 'scam_or_fraud' }), /HELP24_REPORT_NOT_PARTICIPANT/);
  const r = await t.apiReport({ reporter_id: U.alice, target_type: 'application', target_id: APP_BOB, reason: 'payment_issue' });
  assert.equal(r.reported_user_id, U.bob);
  assert.equal(r.application_id, APP_BOB);
  assert.equal(r.post_id, P.aliceRequest);
  assert.match(r.target_snapshot.message, /outside Help24/);
});

test('the category must make sense for the target', async (t) => {
  await t.rejects(t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: U.bob, reason: 'misleading_listing' }), /HELP24_REPORT_INVALID_CATEGORY/);
  await t.rejects(t.apiReport({ reporter_id: U.alice, target_type: 'post', target_id: P.bobOffer, reason: 'threats' }), /HELP24_REPORT_INVALID_CATEGORY/);
});

test('malformed and unknown targets are refused cleanly', async (t) => {
  await t.rejects(t.apiReport({ reporter_id: U.alice, target_type: 'post', target_id: 'not-a-uuid', reason: 'spam' }), /HELP24_REPORT_INVALID_TARGET/);
  await t.rejects(t.apiReport({ reporter_id: U.alice, target_type: 'post', target_id: ID(99999), reason: 'spam' }), /HELP24_REPORT_INVALID_TARGET/);
  await t.rejects(t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: 'u_nobody', reason: 'spam' }), /HELP24_REPORT_INVALID_TARGET/);
});

test('evidence must be the reporter\'s own uploads', async (t) => {
  const ok = await t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: U.bob, reason: 'harassment', evidence: [{ path: `reports/${U.alice}/a.jpg`, mime_type: 'image/jpeg' }] });
  assert.equal(ok.evidence.length, 1);
  await t.rejects(t.apiReport({ reporter_id: U.carol, target_type: 'user', target_id: U.bob, reason: 'harassment', evidence: [{ path: `reports/${U.alice}/a.jpg` }] }), /HELP24_REPORT_INVALID_EVIDENCE/);
  await t.rejects(t.apiReport({ reporter_id: U.carol, target_type: 'user', target_id: U.bob, reason: 'harassment', evidence: [{ path: 'disputes/x/a.jpg' }] }), /HELP24_REPORT_INVALID_EVIDENCE/);
});

test('16: multiple people can report the same target', async (t) => {
  await t.apiReport({ reporter_id: U.alice, target_type: 'post', target_id: P.bobOffer, reason: 'scam_or_fraud' });
  await t.apiReport({ reporter_id: U.carol, target_type: 'post', target_id: P.bobOffer, reason: 'scam_or_fraud' });
  const { rows } = await t.owner('SELECT count(*)::int AS n FROM public.user_reports WHERE target_id = $1', [P.bobOffer]);
  assert.equal(rows[0].n, 2);
});

test('17: the same person reporting the same thing again is refused', async (t) => {
  await t.apiReport({ reporter_id: U.alice, target_type: 'post', target_id: P.bobOffer, reason: 'scam_or_fraud' });
  await t.rejects(t.apiReport({ reporter_id: U.alice, target_type: 'post', target_id: P.bobOffer, reason: 'spam' }), /HELP24_REPORT_DUPLICATE/);
  await t.rejects(t.legacyReport(U.alice, { reporter_id: U.alice, reported_user_id: U.bob, reason: 'spam' }).then(() =>
    t.legacyReport(U.alice, { reporter_id: U.alice, reported_user_id: U.bob, reason: 'harassment' })), /HELP24_REPORT_DUPLICATE/);
});

test('17: an open duplicate older than a day is caught by the unique index', async (t) => {
  await t.apiReport({ reporter_id: U.alice, target_type: 'post', target_id: P.bobOffer, reason: 'scam_or_fraud' });
  await t.owner("SELECT set_config('help24.moderation_write', 'on', true)");
  // Age the report without touching the allegation columns: created_at is
  // guarded, so move it with the guard disabled, as an owner would in ops.
  await t.owner('ALTER TABLE public.user_reports DISABLE TRIGGER trg_user_reports_guard');
  await t.owner(`UPDATE public.user_reports SET created_at = now() - interval '3 days' WHERE reporter_id = $1`, [U.alice]);
  await t.owner('ALTER TABLE public.user_reports ENABLE TRIGGER trg_user_reports_guard');
  await t.rejects(t.apiReport({ reporter_id: U.alice, target_type: 'post', target_id: P.bobOffer, reason: 'spam' }), /user_reports_one_open_per_target/);
});

test('17: ten reports a day per reporter, then refused', async (t) => {
  for (let i = 0; i < 10; i++) {
    await t.apiReport({ reporter_id: U.grace, target_type: 'user', target_id: `u_t${String(i).padStart(2, '0')}`, reason: 'spam' });
  }
  await t.rejects(t.apiReport({ reporter_id: U.grace, target_type: 'user', target_id: 'u_t10', reason: 'spam' }), /HELP24_REPORT_LIMIT/);
});

test('17: five reports a day about one account, then refused', async (t) => {
  for (const id of P.bobExtra.slice(0, 5)) {
    await t.apiReport({ reporter_id: U.dave, target_type: 'post', target_id: id, reason: 'spam' });
  }
  await t.rejects(t.apiReport({ reporter_id: U.dave, target_type: 'post', target_id: P.bobExtra[5], reason: 'spam' }), /HELP24_REPORT_LIMIT/);
});

test('severity rises only when three DIFFERENT people report the same account', async (t) => {
  const a = await t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: U.bob, reason: 'spam' });
  const b = await t.apiReport({ reporter_id: U.carol, target_type: 'user', target_id: U.bob, reason: 'spam' });
  assert.equal(a.severity, 'low');
  assert.equal(b.severity, 'low');
  // Carol again, about a different thing: still two people.
  const c2 = await t.apiReport({ reporter_id: U.carol, target_type: 'post', target_id: P.bobOffer2, reason: 'spam' });
  assert.equal(c2.severity, 'low');
  const c = await t.apiReport({ reporter_id: U.dave, target_type: 'user', target_id: U.bob, reason: 'spam' });
  assert.equal(c.severity, 'medium');
});

test('a report is immutable evidence — even the owner cannot edit or delete it silently', async (t) => {
  const r = await t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: U.bob, reason: 'spam' });
  await t.rejects(t.owner(`UPDATE public.user_reports SET status = 'dismissed' WHERE id = $1`, [r.id]), /HELP24_MODERATION_WRITE_REQUIRED/);
  await t.owner("SELECT set_config('help24.moderation_write', 'on', true)");
  await t.rejects(t.owner(`UPDATE public.user_reports SET details = 'rewritten' WHERE id = $1`, [r.id]), /HELP24_REPORT_IMMUTABLE/);
  await t.rejects(t.owner('DELETE FROM public.user_reports WHERE id = $1', [r.id]), /HELP24_MODERATION_HISTORY_IMMUTABLE/);
  await t.rejects(t.owner('TRUNCATE public.user_reports'), /HELP24_MODERATION_HISTORY_IMMUTABLE|cannot truncate/);
});

test('5: service_role cannot update or delete reports directly', async (t) => {
  const r = await t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: U.bob, reason: 'spam' });
  await t.rejects(t.svc(`UPDATE public.user_reports SET status = 'dismissed' WHERE id = $1`, [r.id]), /permission denied/);
  await t.rejects(t.svc('DELETE FROM public.user_reports WHERE id = $1', [r.id]), /permission denied/);
});

// =============================================================================
// Who may moderate
// =============================================================================

test('21: the app\'s keys cannot call any moderation function', async (t) => {
  const calls = [
    `SELECT public.moderation_apply_sanction('${A.super}', '${U.bob}', 'ban', 'Banning from the app key')`,
    `SELECT public.moderation_lift_restriction('${A.super}', '${ID(1)}', 'Lifting from the app key')`,
    `SELECT public.moderation_resolve_report('${A.super}', '${ID(1)}', 'dismissed', 'x')`,
    `SELECT public.moderation_update_report('${A.super}', '${ID(1)}', 'under_review')`,
    `SELECT public.moderation_add_note('${A.super}', 'x', '${U.bob}')`,
    `SELECT public.moderation_set_content_state('${A.super}', 'post', '${P.bobOffer}', 'remove', 'Removing from the app')`,
    `SELECT public.moderation_denial('${U.bob}', 'post')`,
    `SELECT public.moderation_state_json('${U.bob}')`,
  ];
  for (const sql of calls) {
    await t.rejects(t.anon(sql), /permission denied/);
    await t.rejects(t.user(U.alice)(sql), /permission denied/);
  }
});

test('even a mistaken EXECUTE grant would not let the app moderate', async (t) => {
  await t.owner('GRANT EXECUTE ON FUNCTION public.moderation_apply_sanction(uuid, text, text, text, text, timestamptz, uuid, boolean, boolean, text) TO authenticated');
  await t.rejects(t.user(U.alice)(`SELECT public.moderation_apply_sanction('${A.super}', '${U.bob}', 'ban', 'Banning from the app key')`), /HELP24_MODERATION_FORBIDDEN/);
});

test('21: the app\'s keys cannot read moderation tables or views', async (t) => {
  for (const rel of ['account_restrictions', 'moderation_actions', 'moderation_audit_integrity', 'moderation_account_state']) {
    await t.rejects(t.anon(`SELECT * FROM public.${rel}`), /permission denied/);
    await t.rejects(t.user(U.bob)(`SELECT * FROM public.${rel}`), /permission denied/);
  }
});

test('the backend cannot write moderation state except through the functions', async (t) => {
  await t.rejects(t.svc(`INSERT INTO public.account_restrictions (user_id, kind, reason, created_by) VALUES ($1, 'ban', 'direct write', $2)`, [U.bob, A.super]), /permission denied/);
  await t.rejects(t.svc(`INSERT INTO public.moderation_actions (target_user_id, action_type, admin_id, admin_email, admin_role, reason) VALUES ($1, 'warning_issued', $2, 'x', 'super_admin', 'fabricated')`, [U.bob, A.super]), /permission denied/);
  await t.rejects(t.svc('UPDATE public.users SET is_banned = true WHERE id = $1', [U.bob]), /HELP24_MODERATION_WRITE_REQUIRED/);
  await t.rejects(t.owner('UPDATE public.users SET is_banned = true WHERE id = $1', [U.bob]), /HELP24_MODERATION_WRITE_REQUIRED/);
});

test('an inactive or unknown admin cannot act', async (t) => {
  await t.rejects(t.sanction({ admin: A.inactive, user: U.bob, kind: 'warning' }), /HELP24_ADMIN_INVALID/);
  await t.rejects(t.sanction({ admin: ID(999), user: U.bob, kind: 'warning' }), /HELP24_ADMIN_INVALID/);
});

test('an admin cannot moderate their own marketplace account', async (t) => {
  await t.rejects(t.sanction({ admin: A.super, user: U.adminPerson, kind: 'warning' }), /HELP24_MODERATION_SELF/);
});

// =============================================================================
// Sanctions
// =============================================================================

test('9: a warning is recorded and shown to the user, with no restriction', async (t) => {
  const r = await t.sanction({ admin: A.support, user: U.bob, kind: 'warning', reason: 'Please keep payments inside Help24', note: 'First offence' });
  assert.equal(r.action_type, 'warning_issued');
  assert.equal(r.restriction_id, null);
  const s = await t.statusOf(U.bob);
  assert.equal(s.status, 'active');
  assert.equal(s.warnings.length, 1);
  assert.equal(s.warnings[0].reason, 'Please keep payments inside Help24');
  assert.ok(!JSON.stringify(s).includes('First offence'), 'internal note leaked');
  assert.equal(await t.denial(U.bob, 'post'), null);
});

test('10: a temporary suspension blocks every capability until it ends', async (t) => {
  const r = await t.sanction({ admin: A.senior, user: U.bob, kind: 'suspension', endsAt: t.days(7), reason: 'Repeated payment complaints after review' });
  assert.equal(r.action_type, 'suspension_applied');
  for (const cap of taxonomy.capabilities) assert.equal(await t.denial(U.bob, cap), 'suspended', cap);
  const s = await t.statusOf(U.bob);
  assert.equal(s.status, 'suspended');
  assert.equal(s.restrictions[0].reason, 'Repeated payment complaints after review');
  assert.ok(s.restrictions[0].ends_at);
  assert.match(s.restrictions[0].reference, /^[0-9A-F]{8}$/);
  assert.deepEqual(s.denied_capabilities, [...taxonomy.capabilities].sort());
});

test('suspension terms are validated', async (t) => {
  await t.rejects(t.sanction({ user: U.bob, kind: 'suspension' }), /HELP24_MODERATION_INVALID/);
  await t.rejects(t.sanction({ user: U.bob, kind: 'suspension', endsAt: t.days(400) }), /HELP24_MODERATION_INVALID/);
  await t.rejects(t.sanction({ user: U.bob, kind: 'ban', endsAt: t.days(3) }), /HELP24_MODERATION_INVALID/);
  await t.rejects(t.sanction({ user: U.bob, kind: 'warning', reason: 'too short' }), /HELP24_MODERATION_INVALID/);
  await t.rejects(t.sanction({ user: U.bob, kind: 'delete_account' }), /HELP24_MODERATION_INVALID/);
});

test('11: a permanent ban is durable, mirrored to users.is_banned, and liftable only by an admin', async (t) => {
  const r = await t.sanction({ user: U.bob, kind: 'ban', reason: 'Confirmed fraud against two clients' });
  assert.equal((await t.owner('SELECT is_banned FROM public.users WHERE id = $1', [U.bob])).rows[0].is_banned, true);
  assert.equal(await t.denial(U.bob, 'message'), 'banned');
  await t.rejects(t.sanction({ user: U.bob, kind: 'ban', reason: 'Confirmed fraud against two clients' }), /HELP24_MODERATION_CONFLICT/);
  const l = await t.lift({ restriction: r.restriction_id });
  assert.equal(l.state.status, 'active');
  assert.equal((await t.owner('SELECT is_banned FROM public.users WHERE id = $1', [U.bob])).rows[0].is_banned, false);
  assert.equal(await t.denial(U.bob, 'message'), null);
  await t.rejects(t.lift({ restriction: r.restriction_id }), /HELP24_MODERATION_CONFLICT/);
});

test('a new suspension replaces the running one; a ban ends a suspension', async (t) => {
  const first = await t.sanction({ user: U.bob, kind: 'suspension', endsAt: t.days(7) });
  const second = await t.sanction({ user: U.bob, kind: 'suspension', endsAt: t.days(30) });
  assert.deepEqual(second.superseded, [first.restriction_id]);
  const { rows } = await t.owner('SELECT id, lifted_at, lift_reason FROM public.account_restrictions WHERE user_id = $1 ORDER BY created_at', [U.bob]);
  assert.ok(rows.find((x) => x.id === first.restriction_id).lifted_at);
  const ban = await t.sanction({ user: U.bob, kind: 'ban' });
  assert.deepEqual(ban.superseded, [second.restriction_id]);
  const s = await t.statusOf(U.bob);
  assert.equal(s.status, 'banned');
  assert.equal(s.restrictions.length, 1);
});

test('messaging and marketplace restrictions block only their own capabilities', async (t) => {
  await t.sanction({ admin: A.senior, user: U.bob, kind: 'messaging' });
  assert.equal(await t.denial(U.bob, 'message'), 'messaging_restricted');
  assert.equal(await t.denial(U.bob, 'post'), null);
  await t.sanction({ admin: A.senior, user: U.carol, kind: 'marketplace', endsAt: t.days(14) });
  for (const cap of ['post', 'apply', 'hire', 'pay', 'promote']) assert.equal(await t.denial(U.carol, cap), 'marketplace_restricted', cap);
  for (const cap of ['message', 'review', 'complete', 'payout_config']) assert.equal(await t.denial(U.carol, cap), null, cap);
  assert.equal((await t.statusOf(U.carol)).status, 'restricted');
});

test('an expired or lifted restriction no longer denies anything', async (t) => {
  await t.owner(`INSERT INTO public.account_restrictions (user_id, kind, reason, starts_at, ends_at, created_by)
                 VALUES ($1, 'suspension', 'An old suspension', now() - interval '10 days', now() - interval '1 day', $2)`, [U.bob, A.super]);
  assert.equal(await t.denial(U.bob, 'post'), null);
  assert.equal((await t.statusOf(U.bob)).status, 'active');
});

test('unknown capabilities are an error, not an allow', async (t) => {
  await t.rejects(t.denial(U.bob, 'teleport'), /HELP24_UNKNOWN_CAPABILITY/);
});

test('sanctioning with a report closes it as action_taken; the report must be about that account', async (t) => {
  const rep = await t.apiReport({ reporter_id: U.alice, target_type: 'post', target_id: P.bobOffer, reason: 'scam_or_fraud' });
  await t.rejects(t.sanction({ user: U.carol, kind: 'warning', report: rep.id }), /HELP24_MODERATION_INVALID/);
  const r = await t.sanction({ admin: A.senior, user: U.bob, kind: 'suspension', endsAt: t.days(7), report: rep.id, resolve: true });
  assert.equal(r.report_resolved, true);
  const after = (await t.owner('SELECT * FROM public.user_reports WHERE id = $1', [rep.id])).rows[0];
  assert.equal(after.status, 'resolved');
  assert.equal(after.resolution, 'action_taken');
  assert.equal(after.resolved_by, A.senior);
});

test('hiding listings with a ban hides OPEN listings only, each restorable', async (t) => {
  const r = await t.sanction({ user: U.bob, kind: 'ban', hide: true });
  assert.ok(r.hidden_posts.includes(P.bobOffer));
  assert.ok(!r.hidden_posts.includes(P.bobAssigned), 'a job in flight must not be hidden');
  const { rows } = await t.owner('SELECT archived_by FROM public.posts WHERE id = $1', [P.bobOffer]);
  assert.equal(rows[0].archived_by, 'moderation');
  await t.content({ type: 'post', id: P.bobOffer, action: 'restore', reason: 'Restored after the appeal' });
  assert.equal((await t.owner('SELECT archived_at FROM public.posts WHERE id = $1', [P.bobOffer])).rows[0].archived_at, null);
  await t.rejects(t.sanction({ user: U.carol, kind: 'warning', hide: true }), /HELP24_MODERATION_INVALID/);
});

// =============================================================================
// Reports: triage and closure
// =============================================================================

test('8: dismissing a report closes it and records why', async (t) => {
  const rep = await t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: U.bob, reason: 'harassment' });
  const r = await t.resolve({ report: rep.id, outcome: 'dismissed', reason: 'Insufficient evidence' });
  assert.equal(r.status, 'dismissed');
  const row = (await t.owner('SELECT * FROM public.user_reports WHERE id = $1', [rep.id])).rows[0];
  assert.equal(row.resolution, 'dismissed');
  assert.equal(row.resolution_reason, 'Insufficient evidence');
  assert.ok(row.resolved_at);
  await t.rejects(t.resolve({ report: rep.id, outcome: 'resolved' }), /HELP24_MODERATION_CONFLICT/);
});

test('resolved without a linked action is no_action — the ledger decides, not the caller', async (t) => {
  const rep = await t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: U.bob, reason: 'harassment' });
  assert.equal((await t.resolve({ report: rep.id, outcome: 'resolved' })).resolution, 'no_action');
  const rep2 = await t.apiReport({ reporter_id: U.carol, target_type: 'post', target_id: P.bobOffer, reason: 'misleading_listing' });
  await t.content({ type: 'post', id: P.bobOffer, action: 'remove', report: rep2.id });
  assert.equal((await t.resolve({ report: rep2.id, outcome: 'resolved' })).resolution, 'action_taken');
});

test('triage moves status, severity and assignment, and a closed report can be reopened', async (t) => {
  const rep = await t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: U.bob, reason: 'harassment' });
  const a = await t.triage({ report: rep.id, status: 'under_review', assignTo: A.support });
  assert.equal(a.status, 'under_review');
  assert.equal(a.assigned_admin_id, A.support);
  const b = await t.triage({ report: rep.id, severity: 'critical' });
  assert.equal(b.severity, 'critical');
  await t.rejects(t.triage({ report: rep.id, status: 'resolved' }), /HELP24_MODERATION_INVALID/);
  await t.rejects(t.triage({ report: rep.id, severity: 'critical' }), /HELP24_MODERATION_NO_CHANGE/);
  await t.resolve({ report: rep.id, outcome: 'dismissed' });
  const c = await t.triage({ report: rep.id, status: 'under_review', reason: 'New evidence from a second client' });
  assert.equal(c.reopened, true);
  const row = (await t.owner('SELECT * FROM public.user_reports WHERE id = $1', [rep.id])).rows[0];
  assert.equal(row.resolution, null);
  assert.equal(row.resolved_at, null);
  const types = (await t.owner('SELECT action_type FROM public.moderation_actions WHERE report_id = $1 ORDER BY chain_seq', [rep.id])).rows.map((x) => x.action_type);
  assert.deepEqual(types, ['report_triaged', 'report_triaged', 'report_dismissed', 'report_reopened']);
});

test('internal notes attach to a report or an account and are never shown to the user', async (t) => {
  const rep = await t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: U.bob, reason: 'harassment' });
  await t.svc('SELECT public.moderation_add_note($1, $2, NULL, $3)', [A.support, 'Called the client, confirmed', rep.id]);
  await t.svc('SELECT public.moderation_add_note($1, $2, $3)', [A.support, 'Watch this account', U.bob]);
  const { rows } = await t.owner(`SELECT internal_note FROM public.moderation_actions WHERE action_type = 'note_added' AND target_user_id = $1`, [U.bob]);
  assert.equal(rows.length, 2);
  assert.ok(!JSON.stringify(await t.statusOf(U.bob)).includes('Watch this account'));
  await t.rejects(t.svc('SELECT public.moderation_add_note($1, $2, $3, $4)', [A.support, 'x', U.carol, rep.id]), /HELP24_MODERATION_INVALID/);
});

// =============================================================================
// Content moderation
// =============================================================================

test('a listing can be hidden and restored; only moderation-hidden listings can be restored', async (t) => {
  await t.content({ type: 'post', id: P.bobOffer, action: 'remove' });
  await t.rejects(t.content({ type: 'post', id: P.bobOffer, action: 'remove' }), /HELP24_MODERATION_CONFLICT/);
  await t.content({ type: 'post', id: P.bobOffer, action: 'restore', reason: 'Listing corrected by the owner' });
  await t.rejects(t.content({ type: 'post', id: P.bobOffer2, action: 'restore' }), /HELP24_MODERATION_CONFLICT/);
});

test('19: a listing with a job in progress cannot be hidden — that would strand the job and its money', async (t) => {
  await t.rejects(t.content({ type: 'post', id: P.bobAssigned, action: 'remove' }), /HELP24_MODERATION_CONFLICT: only a listing still open/);
  const p = (await t.owner('SELECT archived_at, status FROM public.posts WHERE id = $1', [P.bobAssigned])).rows[0];
  assert.equal(p.archived_at, null);
  assert.equal(p.status, 'assigned');
  const ledger = (await t.owner(`SELECT count(*)::int AS n FROM public.moderation_actions WHERE content_id = $1`, [P.bobAssigned])).rows[0];
  assert.equal(ledger.n, 0, 'a refused action leaves no ledger row');
});

test('a message can be hidden (content kept as evidence) and restored; a sender-deleted one cannot be restored', async (t) => {
  await t.content({ type: 'message', id: MSG_BOB, action: 'remove' });
  const m = (await t.owner('SELECT deleted_for_everyone, content FROM public.chat_messages WHERE id = $1', [MSG_BOB])).rows[0];
  assert.equal(m.deleted_for_everyone, true);
  assert.match(m.content, /personal number/);
  await t.content({ type: 'message', id: MSG_BOB, action: 'restore', reason: 'Hidden in error, restored' });
  await t.owner(`UPDATE public.chat_messages SET deleted_for_everyone = true WHERE id = $1`, [MSG_ALICE]);
  await t.rejects(t.content({ type: 'message', id: MSG_ALICE, action: 'restore' }), /HELP24_MODERATION_CONFLICT/);
});

// =============================================================================
// The ledger
// =============================================================================

test('14: every action is in the ledger with the actor, role, reason and before/after', async (t) => {
  await t.sanction({ admin: A.senior, user: U.bob, kind: 'suspension', endsAt: t.days(7), reason: 'Repeated scam reports after review', requestId: 'req-123' });
  const a = (await t.owner(`SELECT * FROM public.moderation_actions WHERE target_user_id = $1 AND action_type = 'suspension_applied'`, [U.bob])).rows[0];
  assert.equal(a.admin_id, A.senior);
  assert.equal(a.admin_email, 'senior@help24.test');
  assert.equal(a.admin_role, 'senior_admin');
  assert.equal(a.reason, 'Repeated scam reports after review');
  assert.equal(a.request_id, 'req-123');
  assert.equal(a.previous_state.status, 'active');
  assert.equal(a.new_state.status, 'suspended');
  assert.match(a.row_hash, /^mda1:[0-9a-f]{64}$/);
});

test('the ledger is append-only for everyone, owner included', async (t) => {
  await t.sanction({ user: U.bob, kind: 'warning' });
  const id = (await t.owner('SELECT id FROM public.moderation_actions WHERE target_user_id = $1', [U.bob])).rows[0].id;
  await t.rejects(t.owner(`UPDATE public.moderation_actions SET reason = 'rewritten' WHERE id = $1`, [id]), /HELP24_MODERATION_HISTORY_IMMUTABLE/);
  await t.rejects(t.owner('DELETE FROM public.moderation_actions WHERE id = $1', [id]), /HELP24_MODERATION_HISTORY_IMMUTABLE/);
  await t.rejects(t.owner('TRUNCATE public.moderation_actions'), /HELP24_MODERATION_HISTORY_IMMUTABLE|cannot truncate/);
  await t.rejects(t.svc(`UPDATE public.moderation_actions SET reason = 'rewritten'`), /permission denied/);
});

test('restrictions: terms are immutable, a lift happens once, nothing is deleted', async (t) => {
  const r = await t.sanction({ user: U.bob, kind: 'suspension', endsAt: t.days(7) });
  await t.rejects(t.owner(`UPDATE public.account_restrictions SET ends_at = now() + interval '1 day', lifted_at = now(), lift_reason = 'x' WHERE id = $1`, [r.restriction_id]), /HELP24_MODERATION_HISTORY_IMMUTABLE/);
  await t.rejects(t.owner(`UPDATE public.account_restrictions SET reason = 'softer' WHERE id = $1`, [r.restriction_id]), /HELP24_MODERATION_HISTORY_IMMUTABLE/);
  await t.rejects(t.owner('DELETE FROM public.account_restrictions WHERE id = $1', [r.restriction_id]), /HELP24_MODERATION_HISTORY_IMMUTABLE/);
  await t.lift({ restriction: r.restriction_id });
  await t.rejects(t.owner(`UPDATE public.account_restrictions SET lifted_at = NULL, lift_reason = NULL WHERE id = $1`, [r.restriction_id]), /HELP24_MODERATION_HISTORY_IMMUTABLE/);
});

test('the hash chain verifies, and detects an edit and a removal', async (t) => {
  await t.sanction({ user: U.bob, kind: 'warning' });
  const s = await t.sanction({ user: U.bob, kind: 'suspension', endsAt: t.days(3) });
  await t.lift({ restriction: s.restriction_id });
  await t.sanction({ user: U.carol, kind: 'warning' });
  const check = async () => (await t.svc(`SELECT bool_and(hash_ok) AS h, bool_and(link_ok) AS l, bool_and(seq_ok) AS s, count(*)::int AS n FROM public.moderation_audit_integrity`)).rows[0];
  const clean = await check();
  assert.deepEqual([clean.h, clean.l, clean.s], [true, true, true]);
  assert.equal(clean.n, 4);

  await t.owner('ALTER TABLE public.moderation_actions DISABLE TRIGGER trg_moderation_actions_immutable');
  await t.owner(`UPDATE public.moderation_actions SET reason = 'Quietly softened' WHERE target_user_id = $1 AND action_type = 'suspension_applied'`, [U.bob]);
  assert.equal((await check()).h, false, 'an edited row must fail its hash');
  await t.owner(`DELETE FROM public.moderation_actions WHERE target_user_id = $1 AND chain_seq = 1`, [U.bob]);
  const after = await check();
  assert.equal(after.l && after.s, false, 'a removed row must break the chain');
  await t.owner('ALTER TABLE public.moderation_actions ENABLE TRIGGER trg_moderation_actions_immutable');
});

test('a user\'s chain is gapless across mixed actions', async (t) => {
  const rep = await t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: U.bob, reason: 'harassment' });
  await t.triage({ report: rep.id, status: 'under_review', assignTo: A.support });
  await t.sanction({ user: U.bob, kind: 'ban', hide: true, report: rep.id, resolve: true });
  const { rows } = await t.owner('SELECT chain_seq FROM public.moderation_actions WHERE target_user_id = $1 ORDER BY chain_seq', [U.bob]);
  assert.deepEqual(rows.map((r) => Number(r.chain_seq)), rows.map((_, i) => i + 1));
  assert.ok(rows.length >= 4);
});

// =============================================================================
// Enforcement (migration 116)
// =============================================================================

test('18: an active account posts, applies, opens chats and messages exactly as before', async (t) => {
  await t.insertPostAs(t.user(U.carol), ID(401), U.carol);
  await t.user(U.carol)(`INSERT INTO public.applications (post_id, applicant_temp_id, applicant_user_id, message, proposed_price) VALUES ($1, 'tmp', $2, 'hi', 0)`, [P.bobOffer2, U.carol]);
  await t.user(U.carol)('INSERT INTO public.chats (user1, user2, post_id) VALUES ($1, $2, $3)', [U.bob, U.carol, P.bobOffer2]);
  await t.user(U.carol)(`INSERT INTO public.chat_messages (chat_id, sender_id, content) VALUES ($1, $2, 'Hello Dave')`, [CHAT_CD, U.carol]);
  await t.user(U.carol)(`UPDATE public.posts SET title = 'Edited' WHERE id = $1`, [ID(401)]);
  // The anonymous insert path the app uses before its session exchange lands.
  await t.insertPostAs(t.anon, ID(402), U.carol);
});

// The core flow, at the database layer: REQUEST → APPLY → SELECT → PAYMENT →
// ESCROW → COMPLETION → APPROVAL, with the writes each actor really makes (the
// app's direct inserts as `authenticated`, the backend's as `service_role`).
async function runCoreFlow(t, { client, provider, post }) {
  await t.insertPostAs(t.user(client), post, client, 'request');
  await t.user(provider)(`INSERT INTO public.applications (post_id, applicant_temp_id, applicant_user_id, message, proposed_price)
                         VALUES ($1, 'tmp', $2, 'I can do it', 1500)`, [post, provider]);
  await t.svc(`UPDATE public.posts SET selected_provider_id = $1, status = 'assigned' WHERE id = $2`, [provider, post]);
  const tx = (await t.svc(`INSERT INTO public.transactions (phone, amount, fee, total_paid, status, buyer_user_id, post_id)
                           VALUES ('254700000000', 1500, 50, 1550, 'paid', $1, $2) RETURNING id`, [client, post])).rows[0].id;
  await t.svc(`INSERT INTO public.escrow (post_id, amount, status, transaction_id, provider_id) VALUES ($1, 1500, 'locked', $2, $3)`, [post, tx, provider]);
  await t.svc(`INSERT INTO public.job_completions (post_id, transaction_id, provider_user_id, client_user_id) VALUES ($1, $2, $3, $4)`, [post, tx, provider, client]);
  return tx;
}

test('18/19: the full job and payment flow still works for active accounts', async (t) => {
  const post = ID(420);
  const tx = await runCoreFlow(t, { client: U.carol, provider: U.dave, post });
  await t.svc(`UPDATE public.job_completions SET status = 'approved', reviewed_at = now() WHERE post_id = $1`, [post]);
  await t.svc(`UPDATE public.posts SET status = 'completed' WHERE id = $1`, [post]);
  await t.svc(`UPDATE public.transactions SET status = 'released' WHERE id = $1`, [tx]);
  await t.svc(`UPDATE public.escrow SET status = 'released', released_at = now() WHERE transaction_id = $1`, [tx]);
  const { rows } = await t.owner('SELECT p.status, e.status AS escrow FROM public.posts p JOIN public.escrow e ON e.post_id = p.id::text WHERE p.id = $1', [post]);
  assert.deepEqual(rows[0], { status: 'completed', escrow: 'released' });
});

test('20: a dispute still freezes the job even when one party is banned', async (t) => {
  const post = ID(421);
  const tx = await runCoreFlow(t, { client: U.carol, provider: U.dave, post });
  await t.sanction({ user: U.dave, kind: 'ban', reason: 'Confirmed fraud against two clients' });
  // DisputesService.createDispute + freezeForDispute, as the backend runs them.
  await t.svc(`INSERT INTO public.disputes (post_id, transaction_id, raised_by_user_id, reason, raised_by_role)
               VALUES ($1, $2, $3, 'Work not done', 'client')`, [post, tx, U.carol]);
  await t.svc(`UPDATE public.transactions SET status = 'disputed' WHERE id = $1`, [tx]);
  await t.svc(`UPDATE public.escrow SET status = 'disputed' WHERE transaction_id = $1`, [tx]);
  await t.svc(`UPDATE public.posts SET status = 'disputed' WHERE id = $1`, [post]);
  await t.svc(`UPDATE public.job_completions SET status = 'disputed', reviewed_at = now() WHERE post_id = $1`, [post]);
  // …and the banned provider can still READ the job they are party to.
  const { rows } = await t.user(U.dave)('SELECT status FROM public.posts WHERE id = $1', [post]);
  assert.equal(rows[0].status, 'disputed');
});

test('12: a suspension blocks posting, editing, applying, chatting and messaging', async (t) => {
  // Carol's existing listing, from before the suspension.
  await t.insertPostAs(t.owner, ID(404), U.carol);
  await t.sanction({ admin: A.senior, user: U.carol, kind: 'suspension', endsAt: t.days(7) });
  const carol = t.user(U.carol);
  await t.rejects(t.insertPostAs(carol, ID(403), U.carol), /HELP24_ACCOUNT_RESTRICTED: suspended/);
  await t.rejects(carol(`UPDATE public.posts SET title = 'Pay me on WhatsApp' WHERE id = $1`, [ID(404)]), /HELP24_ACCOUNT_RESTRICTED: suspended/);
  await t.rejects(carol(`INSERT INTO public.applications (post_id, applicant_temp_id, applicant_user_id, message, proposed_price) VALUES ($1, 'tmp', $2, 'hi', 0)`, [P.bobOffer2, U.carol]), /HELP24_ACCOUNT_RESTRICTED/);
  await t.rejects(carol('INSERT INTO public.chats (user1, user2, post_id) VALUES ($1, $2, $3)', [U.bob, U.carol, P.bobOffer2]), /HELP24_ACCOUNT_RESTRICTED/);
  await t.rejects(carol(`INSERT INTO public.chat_messages (chat_id, sender_id, content) VALUES ($1, $2, 'hi')`, [CHAT_CD, U.carol]), /HELP24_ACCOUNT_RESTRICTED/);
  await t.rejects(carol(`UPDATE public.chat_messages SET content = 'edited' WHERE id = $1`, [MSG_CAROL]), /HELP24_ACCOUNT_RESTRICTED/);
  await t.rejects(carol(`UPDATE public.chats SET last_message = 'see my number' WHERE id = $1`, [CHAT_CD]), /HELP24_ACCOUNT_RESTRICTED/);
});

test('12: a suspended account can still read, mark read, and settle', async (t) => {
  await t.sanction({ admin: A.senior, user: U.carol, kind: 'suspension', endsAt: t.days(7) });
  const carol = t.user(U.carol);
  const { rows } = await carol('SELECT count(*)::int AS n FROM public.chat_messages WHERE chat_id = $1', [CHAT_CD]);
  assert.equal(rows[0].n, 1);
  await carol('UPDATE public.chats SET user1_unread_count = 0 WHERE id = $1', [CHAT_CD]);
  await carol(`UPDATE public.chat_messages SET status = 'seen' WHERE id = $1`, [MSG_CAROL]);
  assert.equal((await t.statusOf(U.carol)).status, 'suspended');
});

test('13: a ban blocks the same writes, including an anonymous insert under the banned id', async (t) => {
  await t.sanction({ user: U.carol, kind: 'ban' });
  await t.rejects(t.insertPostAs(t.user(U.carol), ID(405), U.carol), /HELP24_ACCOUNT_RESTRICTED: banned/);
  await t.rejects(t.insertPostAs(t.anon, ID(406), U.carol), /HELP24_ACCOUNT_RESTRICTED: banned/);
  await t.rejects(t.anon(`INSERT INTO public.applications (post_id, applicant_temp_id, applicant_user_id, message, proposed_price) VALUES ($1, 'tmp', $2, 'hi', 0)`, [P.bobOffer2, U.carol]), /HELP24_ACCOUNT_RESTRICTED: banned/);
});

test('a banned JWT is refused even when the row names somebody else', async (t) => {
  await t.sanction({ user: U.carol, kind: 'ban' });
  await t.rejects(t.insertPostAs(t.user(U.carol), ID(407), U.dave), /HELP24_ACCOUNT_RESTRICTED: banned/);
});

test('photos on a restricted author\'s listing are refused', async (t) => {
  await t.insertPostAs(t.owner, ID(408), U.carol);
  await t.sanction({ admin: A.senior, user: U.carol, kind: 'marketplace' });
  await t.rejects(t.user(U.carol)(`INSERT INTO public.post_images (post_id, image_url) VALUES ($1, 'https://x/y.jpg')`, [ID(408)]), /HELP24_ACCOUNT_RESTRICTED: marketplace_restricted/);
});

test('messaging-restricted: can post, cannot message; marketplace-restricted: the reverse', async (t) => {
  await t.sanction({ admin: A.senior, user: U.carol, kind: 'messaging' });
  await t.insertPostAs(t.user(U.carol), ID(409), U.carol);
  await t.rejects(t.user(U.carol)(`INSERT INTO public.chat_messages (chat_id, sender_id, content) VALUES ($1, $2, 'hi')`, [CHAT_CD, U.carol]), /messaging_restricted/);
  await t.sanction({ admin: A.senior, user: U.dave, kind: 'marketplace' });
  await t.user(U.dave)(`INSERT INTO public.chat_messages (chat_id, sender_id, content) VALUES ($1, $2, 'hi')`, [CHAT_CD, U.dave]);
  await t.rejects(t.insertPostAs(t.user(U.dave), ID(410), U.dave), /marketplace_restricted/);
});

test('an expired suspension and a lifted ban no longer block', async (t) => {
  await t.owner(`INSERT INTO public.account_restrictions (user_id, kind, reason, starts_at, ends_at, created_by)
                 VALUES ($1, 'suspension', 'Old', now() - interval '10 days', now() - interval '1 minute', $2)`, [U.carol, A.super]);
  await t.insertPostAs(t.user(U.carol), ID(411), U.carol);
  const ban = await t.sanction({ user: U.dave, kind: 'ban' });
  await t.lift({ restriction: ban.restriction_id });
  await t.insertPostAs(t.user(U.dave), ID(412), U.dave);
});

test('the backend (service_role) is never refused by the triggers — it enforces its own routes', async (t) => {
  await t.sanction({ user: U.carol, kind: 'ban' });
  // e.g. the chat the backend opens when a client selects a provider.
  await t.svc('INSERT INTO public.chats (user1, user2, post_id) VALUES ($1, $2, $3)', [U.bob, U.carol, P.bobAssigned]);
});

test('an owner cannot edit, restore or delete a listing moderation hid, nor fake one', async (t) => {
  await t.content({ type: 'post', id: P.bobOffer, action: 'remove' });
  const bob = t.user(U.bob);
  await t.rejects(bob(`UPDATE public.posts SET archived_at = NULL, archived_by = NULL WHERE id = $1`, [P.bobOffer]), /HELP24_CONTENT_MODERATED/);
  await t.rejects(bob(`UPDATE public.posts SET title = 'x' WHERE id = $1`, [P.bobOffer]), /HELP24_CONTENT_MODERATED/);
  await t.rejects(bob('DELETE FROM public.posts WHERE id = $1', [P.bobOffer]), /HELP24_CONTENT_MODERATED/);
  await t.rejects(bob(`UPDATE public.posts SET archived_at = now(), archived_by = 'moderation' WHERE id = $1`, [P.bobOffer2]), /HELP24_CONTENT_MODERATED/);
  // An ordinary owner edit and delete of a normal listing still work.
  await bob(`UPDATE public.posts SET title = 'Tiling, fairly priced' WHERE id = $1`, [P.bobOffer2]);
  await bob('DELETE FROM public.posts WHERE id = $1', [P.bobExtra[0]]);
});

test('a client cannot un-delete a deleted message', async (t) => {
  await t.user(U.bob)(`UPDATE public.chat_messages SET deleted_for_everyone = true WHERE id = $1`, [MSG_BOB]);
  await t.rejects(t.user(U.bob)(`UPDATE public.chat_messages SET deleted_for_everyone = false WHERE id = $1`, [MSG_BOB]), /HELP24_CONTENT_MODERATED/);
});

test('enforcement fails OPEN (with a warning) if its own machinery breaks', async (t) => {
  await t.sanction({ user: U.carol, kind: 'ban' });
  await t.owner('ALTER TABLE public.account_restrictions RENAME TO account_restrictions_broken');
  const before = t.notices.length;
  await t.insertPostAs(t.user(U.carol), ID(413), U.carol);
  assert.ok(t.notices.slice(before).some((n) => /moderation enforcement skipped/.test(n)), 'expected a WARNING');
  await t.owner('ALTER TABLE public.account_restrictions_broken RENAME TO account_restrictions');
});

// =============================================================================
// What the restricted person sees
// =============================================================================

test('15/22: my_account_status returns only the caller\'s own, user-safe status', async (t) => {
  const rep = await t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: U.bob, reason: 'harassment' });
  await t.sanction({ admin: A.senior, user: U.bob, kind: 'suspension', endsAt: t.days(7), reason: 'Abusive messages to clients', note: 'Reporter is Alice', report: rep.id });
  const s = await t.statusOf(U.bob);
  const text = JSON.stringify(s);
  assert.equal(s.status, 'suspended');
  assert.ok(!text.includes('Alice') && !text.includes('u_alice'), 'reporter identity leaked');
  assert.ok(!text.includes('senior@help24.test') && !text.includes(A.senior), 'admin identity leaked');
  assert.ok(!text.includes('Reporter is Alice'), 'internal note leaked');
  assert.equal((await t.statusOf(U.alice)).status, 'active');
  await t.rejects(t.anon('SELECT public.my_account_status()'), /permission denied/);
});

test('15: a reporter learns nothing about the outcome of their report', async (t) => {
  const rep = await t.apiReport({ reporter_id: U.alice, target_type: 'user', target_id: U.bob, reason: 'harassment' });
  await t.sanction({ user: U.bob, kind: 'ban', report: rep.id, resolve: true });
  const s = await t.statusOf(U.alice);
  assert.equal(s.status, 'active');
  assert.deepEqual(s.restrictions, []);
  assert.deepEqual(s.warnings, []);
});

test('the dashboard view lists restricted accounts only', async (t) => {
  await t.sanction({ admin: A.senior, user: U.bob, kind: 'suspension', endsAt: t.days(7) });
  await t.sanction({ admin: A.senior, user: U.carol, kind: 'messaging' });
  const { rows } = await t.svc('SELECT user_id, account_status, messaging_restricted FROM public.moderation_account_state ORDER BY user_id');
  assert.deepEqual(rows.map((r) => [r.user_id, r.account_status]), [[U.bob, 'suspended'], [U.carol, 'restricted']]);
});

// =============================================================================
// Runner
// =============================================================================

const only = process.argv[2] ? new RegExp(process.argv[2], 'i') : null;
let passed = 0;
const failures = [];

await withDatabase(async (db, notices) => {
  await seed(db);
  for (const { name, fn } of tests) {
    if (only && !only.test(name)) continue;
    await db.query('BEGIN');
    try {
      const c = ctx(db);
      c.notices = notices;
      await fn(c);
      passed++;
      console.log(`  ✓ ${name}`);
    } catch (e) {
      failures.push({ name, error: e });
      console.log(`  ✗ ${name}\n      ${e.message.split('\n').join('\n      ')}`);
    } finally {
      await db.query('ROLLBACK');
    }
  }
}, { applyTwice: true });

console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) process.exit(1);
