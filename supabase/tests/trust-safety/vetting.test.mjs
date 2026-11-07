// Provider vetting (migrations 135–136) — database tests.
//
//   cd supabase/tests/trust-safety && npm install && npm run test:vetting
//
// Same replica and role switching as db.test.mjs: every test runs inside a
// transaction that is rolled back, as `anon` / `authenticated` (with the JWT
// claims PostgREST sets) / `service_role` / the owner. Migrations 114–117, 129
// and the 135 pre-state are applied first, then 135 and 136 — twice, to prove
// they re-run cleanly.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { MIGRATIONS, withDatabase } from './harness.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const migrations = path.resolve(here, '../../migrations');
const M135 = path.join(migrations, '135_provider_vetting.sql');
const M136 = path.join(migrations, '136_provider_vetting_storage.sql');
const PRESTATE = path.join(here, 'fixtures', '135_live_prestate.sql');

const ID = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const U = { client: 'u_client', nanny: 'u_nanny', tutor: 'u_tutor', other: 'u_other', fresh: 'u_fresh' };
const ADMIN = 'admin-reviewer-1';
const P = { babysitRequest: ID(1), babysitJob: ID(2), plumbingRequest: ID(3), tutorRequest: ID(4) };

async function seed(db) {
  for (const [id, name] of Object.entries({ [U.client]: 'Client', [U.nanny]: 'Nanny', [U.tutor]: 'Tutor', [U.other]: 'Other', [U.fresh]: 'Fresh' })) {
    await db.query('INSERT INTO public.users (id, email, name) VALUES ($1, $2, $3)', [id, `${id}@example.com`, name]);
  }
  const post = (id, type, category) => db.query(
    `INSERT INTO public.posts (id, title, description, category, location, urgency, price, type, author_temp_id, author_user_id, employment_type)
     VALUES ($1, 'Listing', 'd', $3, 'Nyali', 'flexible', 1000, $2, 'tmp', '${U.client}', CASE WHEN $2 = 'job' THEN 'full_time' END)`,
    [id, type, category]);
  await post(P.babysitRequest, 'request', 'Babysitting');
  await post(P.babysitJob, 'job', 'Babysitting');
  await post(P.plumbingRequest, 'request', 'Plumbing');
  await post(P.tutorRequest, 'request', 'Tutoring');
}

function ctx(db) {
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

  let fileSeq = 0;
  // Uploads N objects to the private bucket as the user (through 136's policy).
  async function upload(uid, n) {
    const names = [];
    for (let i = 0; i < n; i++) {
      const name = `${uid}/doc-${++fileSeq}.jpg`;
      await user(uid)('INSERT INTO storage.objects (bucket_id, name) VALUES ($1, $2)', ['provider-verifications', name]);
      names.push(name);
    }
    return names;
  }
  async function submit(uid, kind, docType, files) {
    const f = files ?? await upload(uid, docType === 'passport' ? 2 : kind === 'id' ? 3 : 1);
    return (await user(uid)('SELECT public.submit_provider_verification($1, $2, $3) AS id', [kind, docType, f])).rows[0].id;
  }
  async function review(id, decision, reason = null) {
    return (await svc('SELECT public.review_provider_verification($1, $2, $3, $4) AS r', [id, decision, reason, ADMIN])).rows[0].r;
  }
  async function verifyId(uid) {
    return review(await submit(uid, 'id', 'national_id'), 'approve');
  }
  async function careCheck(uid, docType = 'certificate') {
    await verifyId(uid);
    return review(await submit(uid, 'care', docType), 'approve');
  }
  const offer = (uid, id, category, extra = {}) => {
    const cols = ['id', 'title', 'description', 'category', 'location', 'urgency', 'price', 'type', 'author_temp_id', 'author_user_id', ...Object.keys(extra)];
    const vals = [id, 'My service', 'd', category, 'Nyali', 'flexible', 500, 'offer', 'tmp', uid, ...Object.values(extra)];
    return user(uid)(
      `INSERT INTO public.posts (${cols.join(', ')}) VALUES (${cols.map((_, i) => `$${i + 1}`).join(', ')}) RETURNING vetting_label, vetting_hide_at`,
      vals);
  };
  const apply = (uid, postId) => user(uid)(
    `INSERT INTO public.applications (post_id, applicant_temp_id, applicant_user_id, message, proposed_price)
     VALUES ($1, 'tmp', $2, 'I can help', 900)`, [postId, uid]);
  const postRow = async (id) => (await owner('SELECT * FROM public.posts WHERE id = $1', [id])).rows[0];
  const profile = async (uid) => (await anon('SELECT id_verified, care_status FROM public.public_profiles WHERE id = $1', [uid])).rows[0];
  const meets = async (uid, tier, pending) => (await svc('SELECT public.provider_meets_vetting($1, $2, $3) AS ok', [uid, tier, pending])).rows[0].ok;
  const hoursFromNow = (d) => (new Date(d).getTime() - Date.now()) / 3_600_000;

  return { db, owner, svc, user, anon, rejects, upload, submit, review, verifyId, careCheck, offer, apply, postRow, profile, meets, hoursFromNow };
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

// ── Configuration ────────────────────────────────────────────────────────────

test('the two tiers are set on exactly the agreed categories', async ({ owner }) => {
  const { rows } = await owner('SELECT id, vetting_tier FROM public.categories WHERE vetting_tier IS NOT NULL ORDER BY id');
  assert.deepEqual(rows.map((r) => `${r.id}:${r.vetting_tier}`), [
    'babysitting:care', 'caregiving:care', 'driver:id', 'house-cleaning:id', 'security-guard:id', 'tutoring:id',
  ]);
});

test('clients can neither read nor write the submissions table', async (t) => {
  await t.rejects(t.user(U.nanny)('SELECT * FROM public.provider_verifications'), /permission denied/);
  await t.rejects(t.user(U.nanny)(
    `INSERT INTO public.provider_verifications (user_id, kind, document_type, files, status)
     VALUES ($1, 'id', 'national_id', ARRAY['x'], 'approved')`, [U.nanny]), /permission denied/);
  await t.rejects(t.anon('SELECT public.submit_provider_verification($1, $2, $3)', ['id', 'national_id', ['a', 'b', 'c']]), /permission denied/);
  await t.rejects(t.user(U.nanny)('SELECT public.review_provider_verification($1, $2, $3, $4)', [ID(9), 'approve', null, 'me']), /permission denied/);
  await t.rejects(t.user(U.nanny)('SELECT public.vetting_sweep()'), /permission denied/);
});

// ── Offering work ────────────────────────────────────────────────────────────

test('an unverified provider cannot offer care or ID-check work, but can offer anything else', async (t) => {
  await t.rejects(t.offer(U.nanny, ID(10), 'Babysitting'), /HELP24_VERIFICATION_REQUIRED: offering this work needs a Care check/);
  await t.rejects(t.offer(U.nanny, ID(11), 'Tutoring'), /HELP24_VERIFICATION_REQUIRED: offering this work needs an ID check/);
  const { rows } = await t.offer(U.nanny, ID(12), 'Plumbing');
  assert.equal(rows[0].vetting_label, null);
});

test('a customer can post a care REQUEST without any check', async (t) => {
  await t.user(U.other)(
    `INSERT INTO public.posts (id, title, description, category, location, urgency, price, type, author_temp_id, author_user_id)
     VALUES ($1, 'Need a sitter', 'd', 'Babysitting', 'Nyali', 'flexible', 500, 'request', 'tmp', $2)`, [ID(13), U.other]);
});

test('an ID check opens ID-tier work but not care work', async (t) => {
  await t.verifyId(U.tutor);
  const { rows } = await t.offer(U.tutor, ID(14), 'Tutoring');
  assert.equal(rows[0].vetting_label, null);
  await t.rejects(t.offer(U.tutor, ID(15), 'Babysitting'), /needs a Care check/);
  await t.apply(U.tutor, P.tutorRequest);
});

test('pending certificate (receipt approved): may offer care work, labelled, hidden in 30 days', async (t) => {
  await t.careCheck(U.nanny, 'receipt');
  const { rows } = await t.offer(U.nanny, ID(16), 'Babysitting');
  assert.equal(rows[0].vetting_label, 'certificate_pending');
  const h = t.hoursFromNow(rows[0].vetting_hide_at);
  assert.ok(h > 30 * 24 - 1 && h <= 30 * 24, `hide in ~30 days, got ${h}h`);
  assert.deepEqual(await t.profile(U.nanny), { id_verified: true, care_status: 'pending' });
});

test('pending certificate: may NOT apply to care requests or jobs, and is not hireable', async (t) => {
  await t.careCheck(U.nanny, 'receipt');
  await t.rejects(t.apply(U.nanny, P.babysitRequest), /applying for this work needs a completed Care check/);
  await t.rejects(t.apply(U.nanny, P.babysitJob), /completed Care check/);
  assert.equal(await t.meets(U.nanny, 'care', false), false);
  assert.equal(await t.meets(U.nanny, 'care', true), true);
  // Ordinary work is unaffected.
  await t.apply(U.nanny, P.plumbingRequest);
});

test('certificate approved: full access, and the label on existing offers clears', async (t) => {
  await t.careCheck(U.nanny, 'receipt');
  await t.offer(U.nanny, ID(17), 'Babysitting');
  const cert = await t.submit(U.nanny, 'care', 'certificate');
  const r = await t.review(cert, 'approve');
  assert.equal(r.listings_changed, 1);
  const p = await t.postRow(ID(17));
  assert.equal(p.vetting_label, null);
  assert.equal(p.vetting_hide_at, null);
  await t.apply(U.nanny, P.babysitRequest);
  assert.equal(await t.meets(U.nanny, 'care', false), true);
  assert.deepEqual(await t.profile(U.nanny), { id_verified: true, care_status: 'checked' });
});

test('a receipt that runs out hides the offer; the author cannot reopen it; the certificate does', async (t) => {
  await t.careCheck(U.nanny, 'receipt');
  await t.offer(U.nanny, ID(18), 'Babysitting');
  await t.owner(`UPDATE public.provider_verifications SET expires_at = now() - interval '1 minute' WHERE user_id = $1 AND document_type = 'receipt'`, [U.nanny]);
  await t.owner(`UPDATE public.posts SET vetting_hide_at = now() - interval '1 minute' WHERE id = $1`, [ID(18)]);

  const swept = (await t.svc('SELECT public.vetting_sweep() AS n')).rows[0].n;
  assert.equal(swept, 1);
  let p = await t.postRow(ID(18));
  assert.equal(p.archived_by, 'vetting');
  assert.ok(p.archived_at);
  assert.equal(p.vetting_label, 'not_verified');
  assert.equal((await t.profile(U.nanny)).care_status, null);

  await t.rejects(t.user(U.nanny)('UPDATE public.posts SET archived_at = NULL, archived_by = NULL WHERE id = $1', [ID(18)]),
    /reopens when your verification is approved/);

  await t.review(await t.submit(U.nanny, 'care', 'certificate'), 'approve');
  p = await t.postRow(ID(18));
  assert.equal(p.archived_at, null);
  assert.equal(p.archived_by, null);
  assert.equal(p.vetting_label, null);
});

test('the sweep leaves listings alone before their time', async (t) => {
  await t.careCheck(U.nanny, 'receipt');
  await t.offer(U.nanny, ID(19), 'Babysitting');
  assert.equal((await t.svc('SELECT public.vetting_sweep() AS n')).rows[0].n, 0);
  assert.equal((await t.postRow(ID(19))).archived_at, null);
});

// ── Applying ─────────────────────────────────────────────────────────────────

test('applying to care or ID-tier requests needs the full check; other work does not', async (t) => {
  await t.rejects(t.apply(U.other, P.babysitRequest), /HELP24_VERIFICATION_REQUIRED/);
  await t.rejects(t.apply(U.other, P.tutorRequest), /applying for this work needs an ID check/);
  await t.apply(U.other, P.plumbingRequest);
});

// ── The client cannot write Help24's columns ─────────────────────────────────

test('authors cannot set the vetting label, hide time, or mark a listing hidden for verification', async (t) => {
  const { rows } = await t.offer(U.other, ID(20), 'Plumbing', { vetting_label: 'not_verified', vetting_hide_at: new Date().toISOString() });
  assert.equal(rows[0].vetting_label, null);
  assert.equal(rows[0].vetting_hide_at, null);
  await t.rejects(t.offer(U.other, ID(21), 'Plumbing', { archived_by: 'vetting', archived_at: new Date().toISOString() }),
    /only Help24 can hide a listing for verification/);
  await t.rejects(t.user(U.other)(`UPDATE public.posts SET archived_by = 'vetting', archived_at = now() WHERE id = $1`, [ID(20)]),
    /only Help24 can hide a listing for verification/);
});

test('editing a labelled offer keeps its label and clock; moving it into a care category is checked', async (t) => {
  await t.careCheck(U.nanny, 'receipt');
  const before = (await t.offer(U.nanny, ID(22), 'Babysitting')).rows[0];
  await t.user(U.nanny)(`UPDATE public.posts SET title = 'Evening sitter', vetting_label = NULL WHERE id = $1`, [ID(22)]);
  const after = await t.postRow(ID(22));
  assert.equal(after.vetting_label, 'certificate_pending');
  assert.equal(after.vetting_hide_at.toISOString(), new Date(before.vetting_hide_at).toISOString());

  await t.offer(U.other, ID(23), 'Plumbing');
  await t.rejects(t.user(U.other)(`UPDATE public.posts SET category = 'Caregiving' WHERE id = $1`, [ID(23)]), /needs a Care check/);
});

test('an author re-publishing their own archived care offer is checked again', async (t) => {
  await t.careCheck(U.nanny);
  await t.offer(U.nanny, ID(24), 'Babysitting');
  await t.user(U.nanny)('UPDATE public.posts SET archived_at = now(), archived_by = $2 WHERE id = $1', [ID(24), U.nanny]);
  // Certificate taken away (e.g. found forged): reopening is refused.
  await t.owner(`UPDATE public.provider_verifications SET status = 'rejected', rejection_reason = 'forged' WHERE user_id = $1 AND kind = 'care'`, [U.nanny]);
  await t.rejects(t.user(U.nanny)('UPDATE public.posts SET archived_at = NULL, archived_by = NULL WHERE id = $1', [ID(24)]), /needs a Care check/);
});

// ── Listings from before vetting ─────────────────────────────────────────────

test('older offers get 14 days with "not_verified", then are hidden; verifying reopens them', async (t) => {
  // As they were before 135: written by the owner, so no trigger judged them.
  await t.owner(
    `INSERT INTO public.posts (id, title, description, category, location, urgency, price, type, author_temp_id, author_user_id)
     VALUES ($1, 'Babysitting by a lash tech', 'd', 'Babysitting', 'Nyali', 'flexible', 500, 'offer', 'tmp', $2),
            ($3, 'Plumbing', 'd', 'Plumbing', 'Nyali', 'flexible', 500, 'offer', 'tmp', $2)`, [ID(30), U.other, ID(31)]);
  await t.owner(fs.readFileSync(M135, 'utf8'));
  let p = await t.postRow(ID(30));
  assert.equal(p.vetting_label, 'not_verified');
  const h = t.hoursFromNow(p.vetting_hide_at);
  assert.ok(h > 14 * 24 - 1 && h <= 14 * 24, `hide in ~14 days, got ${h}h`);
  assert.equal((await t.postRow(ID(31))).vetting_label, null);

  // Re-applying never restarts the clock.
  await t.owner(`UPDATE public.posts SET vetting_hide_at = now() - interval '1 minute' WHERE id = $1`, [ID(30)]);
  await t.owner(fs.readFileSync(M135, 'utf8'));
  assert.ok(t.hoursFromNow((await t.postRow(ID(30))).vetting_hide_at) < 0);

  await t.svc('SELECT public.vetting_sweep()');
  p = await t.postRow(ID(30));
  assert.equal(p.archived_by, 'vetting');

  await t.careCheck(U.other);
  p = await t.postRow(ID(30));
  assert.equal(p.archived_at, null);
  assert.equal(p.vetting_label, null);
});

test('a rejection during the notice period does not cut it short', async (t) => {
  await t.owner(
    `INSERT INTO public.posts (id, title, description, category, location, urgency, price, type, author_temp_id, author_user_id)
     VALUES ($1, 'Old tutoring offer', 'd', 'Tutoring', 'Nyali', 'flexible', 500, 'offer', 'tmp', $2)`, [ID(32), U.other]);
  await t.owner(fs.readFileSync(M135, 'utf8'));
  await t.review(await t.submit(U.other, 'id', 'passport'), 'reject', 'Photo is blurred');
  const p = await t.postRow(ID(32));
  assert.equal(p.archived_at, null);
  assert.equal(p.vetting_label, 'not_verified');
});

// ── Submitting ───────────────────────────────────────────────────────────────

test('submit: the right number of photos, your own uploads, really uploaded', async (t) => {
  const two = await t.upload(U.fresh, 2);
  await t.rejects(t.submit(U.fresh, 'id', 'national_id', two), /wrong number of photos/);
  await t.rejects(t.submit(U.fresh, 'id', 'national_id', [...two, `${U.other}/doc-x.jpg`]), /must be your own uploads/);
  await t.rejects(t.submit(U.fresh, 'id', 'national_id', [...two, `${U.fresh}/../${U.other}/x.jpg`]), /must be your own uploads/);
  await t.rejects(t.submit(U.fresh, 'id', 'national_id', [...two, `${U.fresh}/never-uploaded.jpg`]), /did not finish uploading/);
  await t.rejects(t.submit(U.fresh, 'id', 'drivers_licence', two), /unknown document type/);
  await t.submit(U.fresh, 'id', 'passport', two);
});

test('submit: one in review at a time; care needs the ID sent first; nothing twice once approved', async (t) => {
  await t.rejects(t.submit(U.fresh, 'care', 'receipt'), /send your ID first/);
  const idSub = await t.submit(U.fresh, 'id', 'alien_id');
  await t.rejects(t.submit(U.fresh, 'id', 'national_id'), /still reviewing/);
  await t.submit(U.fresh, 'care', 'receipt');       // allowed while the ID is in review
  await t.rejects(t.submit(U.fresh, 'care', 'certificate'), /still reviewing/);
  await t.review(idSub, 'approve');
  await t.rejects(t.submit(U.fresh, 'id', 'national_id'), /already verified/);
});

test('submit: a banned account and a stranger without a profile are refused', async (t) => {
  await t.owner(
    `INSERT INTO public.admin_users (id, email, name, role, token_hash, active)
     VALUES ($1, 'super@help24.test', 'Super', 'super_admin', 'hash-super', true)`, [ID(900)]);
  await t.svc('SELECT public.moderation_apply_sanction($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)',
    [ID(900), U.fresh, 'ban', 'Fraudulent documents after review', null, null, null, false, false, null]);
  await t.rejects(t.submit(U.fresh, 'id', 'passport', [`${U.fresh}/a.jpg`, `${U.fresh}/b.jpg`]), /HELP24_ACCOUNT_RESTRICTED/);
  await t.rejects(t.user('u_nobody')('SELECT public.submit_provider_verification($1, $2, $3)', ['id', 'passport', ['u_nobody/a.jpg', 'u_nobody/b.jpg']]), /finish setting up your profile/);
});

// ── Reviewing ────────────────────────────────────────────────────────────────

test('review: care cannot be approved before the ID; reject needs a reason; one decision only', async (t) => {
  const idSub = await t.submit(U.fresh, 'id', 'national_id');
  const care = await t.submit(U.fresh, 'care', 'certificate');
  await t.rejects(t.review(care, 'approve'), /approve this provider's ID first/);
  await t.rejects(t.review(idSub, 'reject', '  '), /give the provider a reason/);
  await t.review(idSub, 'reject', 'The selfie does not show the ID card');
  await t.rejects(t.review(idSub, 'approve'), /already rejected/);
  // After a rejection the provider can send again.
  await t.submit(U.fresh, 'id', 'national_id');
});

test('review: approving the ID turns on users.is_verified and the public "ID verified"', async (t) => {
  assert.deepEqual(await t.profile(U.fresh), { id_verified: false, care_status: null });
  await t.verifyId(U.fresh);
  assert.equal((await t.owner('SELECT is_verified FROM public.users WHERE id = $1', [U.fresh])).rows[0].is_verified, true);
  assert.deepEqual(await t.profile(U.fresh), { id_verified: true, care_status: null });
});

test('review: a receipt expires 30 days after approval', async (t) => {
  await t.verifyId(U.fresh);
  const r = await t.review(await t.submit(U.fresh, 'care', 'receipt'), 'approve');
  const h = t.hoursFromNow(r.expires_at);
  assert.ok(h > 30 * 24 - 1 && h <= 30 * 24);
});

// ── What the member and the public can see ───────────────────────────────────

test('my_verification_status: own status and the tier list, never file paths or reviewer', async (t) => {
  await t.verifyId(U.fresh);
  await t.submit(U.fresh, 'care', 'receipt');
  const s = (await t.user(U.fresh)('SELECT public.my_verification_status() AS s')).rows[0].s;
  assert.equal(s.id_verified, true);
  assert.equal(s.care_status, 'none');
  assert.equal(s.latest.id.status, 'approved');
  assert.equal(s.latest.care.status, 'pending');
  assert.equal(s.latest.care.document_type, 'receipt');
  assert.equal(s.tiers.Babysitting, 'care');
  assert.equal(s.tiers.Tutoring, 'id');
  const text = JSON.stringify(s);
  assert.ok(!text.includes('doc-') && !text.includes(ADMIN), 'no files or reviewer in the payload');
  assert.equal((await t.anon('SELECT public.my_verification_status() AS s').catch(() => ({ rows: [{ s: 'denied' }] }))).rows[0].s, 'denied');
});

test('public_profiles keeps every earlier column in order and appends the two outcomes', async ({ owner }) => {
  const { rows } = await owner(
    `SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'public_profiles' ORDER BY ordinal_position`);
  assert.deepEqual(rows.map((r) => r.column_name), [
    'id', 'name', 'avatar_url', 'has_phone', 'profile_image', 'profession', 'bio', 'created_at', 'last_seen', 'is_online',
    'id_verified', 'care_status',
  ]);
});

// ── Storage (136) ────────────────────────────────────────────────────────────

test('storage: the bucket is private; members upload only into their own folder and read nothing back', async (t) => {
  const b = (await t.owner(`SELECT public, allowed_mime_types FROM storage.buckets WHERE id = 'provider-verifications'`)).rows[0];
  assert.equal(b.public, false);
  assert.ok(b.allowed_mime_types.includes('application/pdf'));
  await t.upload(U.fresh, 1);
  await t.rejects(t.user(U.fresh)('INSERT INTO storage.objects (bucket_id, name) VALUES ($1, $2)', ['provider-verifications', `${U.other}/x.jpg`]), /row-level security/);
  const seen = await t.user(U.fresh)(`SELECT count(*)::int AS n FROM storage.objects WHERE bucket_id = 'provider-verifications'`);
  assert.equal(seen.rows[0].n, 0);
});

// =============================================================================
// Runner
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
}, { files: [...MIGRATIONS, PRESTATE, M135, M136, M135, M136] });

console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) process.exit(1);
