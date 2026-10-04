// LIVE security test of the files endpoint against PRODUCTION data.
//
//   node scripts/live-security-test.mjs --identity local
//       In-process app, real Supabase rows and objects, identities signed by a
//       throwaway local key the in-process verifier is told to trust. Makes NO
//       writes anywhere. Proves the authorization rule against live data.
//
//   node scripts/live-security-test.mjs --identity firebase --base <url>
//       Real Firebase ID tokens, minted with the Admin SDK (custom token →
//       signInWithCustomToken) for the two participants and for a probe uid
//       that is in no chat, then sent over HTTP to <url> — the local server
//       (scripts/serve-local.mjs) or the deployed Worker. Signing in updates
//       Firebase's last-sign-in time for those uids, and creates the probe uid
//       the first time: run only with approval.
//
// Writes nothing to Supabase: uploads are probed only as callers who must be
// refused before storage is touched. Never prints a token or a key. A JSON
// report (message ids shortened) goes to reports/, which is gitignored.

import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createApp } from '../src/app.js';
import { createFirebaseVerifier } from '../src/firebase-auth.js';
import { createSupabase } from '../src/supabase.js';
import { TYPES, objectForMessage, participantsOf, sanitizeFilename } from '../src/policy.js';
import { b64urlEncode } from '../src/tokens.js';
import { REPO_ROOT, firebaseWebApiKey, loadBackendEnv, need, requireFrom } from './lib/env.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : fallback;
};
const identity = arg('identity', 'local');
const base = arg('base', null);
const probeUid = arg('probe-uid', 'help24-files-security-probe');
if (!['local', 'firebase'].includes(identity)) throw new Error('--identity local|firebase');
if (identity === 'firebase' && !base) throw new Error('--identity firebase needs --base <url>');

const env = loadBackendEnv();
need(env, 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'FIREBASE_PROJECT_ID');
const SB = env.SUPABASE_URL.replace(/\/+$/, '');
const SB_HOST = new URL(SB).host;
const projectId = env.FIREBASE_PROJECT_ID;
const admin = createSupabase({ url: SB, serviceKey: env.SUPABASE_SERVICE_ROLE_KEY });

const results = [];
function check(name, pass, detail = '') {
  results.push({ name, pass: Boolean(pass), detail });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? `  — ${detail}` : ''}`);
}
function note(name, detail) {
  results.push({ name, pass: null, detail });
  console.log(`INFO  ${name}  — ${detail}`);
}
const short = (id) => String(id).slice(0, 8);
const sha = (buf) => createHash('sha256').update(buf).digest('hex');
const auth = (token) => ({ authorization: `Bearer ${token}` });

/** Every header and the Location, scanned for the storage host or the word itself. */
function leaks(res, bodyText = '') {
  const text = [...res.headers.entries()].map(([k, v]) => `${k}: ${v}`).join('\n') + bodyText;
  return /supabase|sb_secret|sb_publishable/i.test(text) || text.includes(SB_HOST);
}

// ── identities ───────────────────────────────────────────────────────────────

let call;
let tokenFor;
let linkTarget;

if (identity === 'local') {
  const pair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  );
  const kid = `local-${randomBytes(4).toString('hex')}`;
  const jwk = { ...(await crypto.subtle.exportKey('jwk', pair.publicKey)), kid, alg: 'RS256' };
  const enc = new TextEncoder();
  tokenFor = async (uid) => {
    const now = Math.floor(Date.now() / 1000);
    const h = b64urlEncode(enc.encode(JSON.stringify({ alg: 'RS256', kid, typ: 'JWT' })));
    const p = b64urlEncode(enc.encode(JSON.stringify({
      iss: `https://securetoken.google.com/${projectId}`, aud: projectId, sub: uid, user_id: uid,
      iat: now - 5, auth_time: now - 5, exp: now + 900,
    })));
    const s = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', pair.privateKey, enc.encode(`${h}.${p}`));
    return `${h}.${p}.${b64urlEncode(new Uint8Array(s))}`;
  };
  const kv = new Map();
  const app = createApp({
    verifyIdToken: createFirebaseVerifier({
      projectId,
      fetchImpl: async () => new Response(JSON.stringify({ keys: [jwk] }), { headers: { 'cache-control': 'max-age=3600' } }),
    }),
    supabase: createSupabase({ url: SB, serviceKey: env.SUPABASE_SERVICE_ROLE_KEY }),
    nonces: { burn: async (n) => (kv.has(n) ? false : (kv.set(n, 1), true)) },
    signingSecret: randomBytes(32).toString('base64url'),
  });
  call = (path, init = {}) => app.fetch(new Request(`https://files.help24.co.ke${path}`, init));
  linkTarget = 'https://files.help24.co.ke';
} else {
  need(env, 'FIREBASE_CLIENT_EMAIL', 'FIREBASE_PRIVATE_KEY');
  const { initializeApp, cert } = requireFrom('firebase-admin/app');
  const { getAuth } = requireFrom('firebase-admin/auth');
  const fb = initializeApp(
    { credential: cert({ projectId, clientEmail: env.FIREBASE_CLIENT_EMAIL, privateKey: env.FIREBASE_PRIVATE_KEY.replace(/\\n/g, '\n') }) },
    'files-security-probe',
  );
  const apiKey = firebaseWebApiKey();
  const cache = new Map();
  tokenFor = async (uid) => {
    if (cache.has(uid)) return cache.get(uid);
    const custom = await getAuth(fb).createCustomToken(uid);
    const res = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${apiKey}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ token: custom, returnSecureToken: true }),
    });
    if (!res.ok) throw new Error(`signInWithCustomToken failed with HTTP ${res.status}`);
    const { idToken } = await res.json();
    cache.set(uid, idToken);
    return idToken;
  };
  const origin = base.replace(/\/+$/, '');
  call = (path, init = {}) => fetch(`${origin}${path}`, { ...init, redirect: 'manual' });
  linkTarget = origin;
}

// ── the live rows ────────────────────────────────────────────────────────────

const rowsRes = await fetch(
  `${SB}/rest/v1/chat_messages?select=id,chat_id,sender_id,type,content,attachment_url,deleted_for_everyone,chats(user1,user2)` +
    `&attachment_url=not.is.null&order=created_at.asc&limit=200`,
  { headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY } },
);
if (!rowsRes.ok) throw new Error(`could not read attachment rows: HTTP ${rowsRes.status}`);
const rows = await rowsRes.json();
const participants = [...new Set(rows.flatMap(participantsOf))];
console.log(`\n${rows.length} attachment rows in ${new Set(rows.map((r) => r.chat_id)).size} chats, ${participants.length} participants; identity mode: ${identity}\n`);

const outsiderUid = identity === 'local' ? `security-probe-${randomBytes(6).toString('hex')}` : probeUid;
const probeChats = await fetch(`${SB}/rest/v1/chats?select=id&or=(user1.eq.${encodeURIComponent(outsiderUid)},user2.eq.${encodeURIComponent(outsiderUid)})&limit=1`, {
  headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY },
}).then((r) => r.json());
check('the outsider identity is in no chat at all', Array.isArray(probeChats) && probeChats.length === 0, `uid ${short(outsiderUid)}…`);

const tokens = {};
for (const uid of [...participants, outsiderUid]) tokens[uid] = await tokenFor(uid);
const outsider = tokens[outsiderUid];

// What each row SHOULD serve, read straight from storage with the service key.
const expected = new Map();
for (const row of rows) {
  const object = objectForMessage(row, SB);
  if (!object) continue;
  const res = await admin.getObject(object.bucket, object.key);
  if (res.status === 200) expected.set(row.id, { sha: sha(Buffer.from(await res.arrayBuffer())), ext: object.ext, legacy: object.legacy });
  else await res.body?.cancel();
}

// ── 1. every attachment, every kind of caller ────────────────────────────────

const missingBody = await (await call(`/d/${randomUUID()}`, { headers: auth(outsider) })).text();

for (const row of rows) {
  const label = `${row.type} ${short(row.id)}${row.deleted_for_everyone ? ' [deleted]' : ''}`;
  const anon = await call(`/d/${row.id}`);
  const anonText = await anon.text();
  check(`anonymous caller cannot read ${label}`, anon.status === 401 && !leaks(anon, anonText), `HTTP ${anon.status}`);

  const stranger = await call(`/d/${row.id}`, { headers: auth(outsider) });
  const strangerText = await stranger.text();
  check(
    `NON-PARTICIPANT cannot read ${label}`,
    stranger.status === 404 && strangerText === missingBody && !leaks(stranger, strangerText),
    `HTTP ${stranger.status}${strangerText === missingBody ? ', identical to a nonexistent id' : ', body differs from nonexistent!'}`,
  );

  for (const [n, uid] of participantsOf(row).entries()) {
    const res = await call(`/d/${row.id}`, { headers: auth(tokens[uid]) });
    const who = `participant ${n === 0 ? 'A' : 'B'}`;
    if (row.deleted_for_everyone) {
      const text = await res.text();
      check(`${who} gets 410 for ${label}`, res.status === 410 && !leaks(res, text), `HTTP ${res.status}`);
      continue;
    }
    const want = expected.get(row.id);
    const buf = Buffer.from(await res.arrayBuffer());
    const got = sha(buf);
    const cd = res.headers.get('content-disposition') ?? '';
    const nameOk =
      row.type !== 'file' || cd.includes(encodeURIComponent(sanitizeFilename(row.content)).replace(/['()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`));
    check(
      `${who} reads ${label}`,
      res.status === 200 && want && got === want.sha && res.headers.get('content-type') === TYPES[want.ext].mime && nameOk && !leaks(res),
      `HTTP ${res.status}, ${buf.length} B, sha256 ${got.slice(0, 10)}…${want && got === want.sha ? ' = stored object' : ' ≠ stored object'}` +
        `${want?.legacy ? ' (legacy bucket)' : ' (private bucket)'}; ${cd.split(';')[0]}; filename*=${cd.split("filename*=UTF-8''")[1] ?? '?'}`,
    );
  }
}

// ── 2. browser links ────────────────────────────────────────────────────────

const docRow = rows.find((r) => r.type === 'file' && !r.deleted_for_everyone && expected.has(r.id));
const otherRow = rows.find((r) => r !== docRow && !r.deleted_for_everyone && expected.has(r.id));
if (docRow) {
  const [a] = participantsOf(docRow);
  const minted = await call(`/links/${docRow.id}`, { method: 'POST', headers: auth(tokens[a]) });
  const mintedText = await minted.text();
  const link = minted.status === 200 ? JSON.parse(mintedText) : null;
  check('participant mints a one-time document link', minted.status === 200 && link?.expires_in === 120 && !leaks(minted, mintedText), `HTTP ${minted.status}`);
  if (link) {
    const u = new URL(link.url);
    check('the link is on the Help24 host, not Supabase', u.origin === linkTarget && u.pathname === `/d/${docRow.id}` && !u.host.includes('supabase'), u.origin + u.pathname);
    const path = u.pathname + u.search;
    const ex = await call(path);
    const setCookie = ex.headers.getSetCookie?.()[0] ?? ex.headers.get('set-cookie') ?? '';
    check(
      'opening the link sets a document cookie and redirects to the clean URL',
      ex.status === 303 && ex.headers.get('location') === `/d/${docRow.id}` && /HttpOnly; Secure; SameSite=Lax/.test(setCookie) && setCookie.includes(`Path=/d/${docRow.id}`),
      `HTTP ${ex.status} → ${ex.headers.get('location')}`,
    );
    const cookie = setCookie.split(';')[0];
    const doc = await call(`/d/${docRow.id}`, { headers: { cookie } });
    const docBuf = Buffer.from(await doc.arrayBuffer());
    check(
      'the browser gets the document through files.help24.co.ke',
      doc.status === 200 && sha(docBuf) === expected.get(docRow.id).sha && doc.headers.get('cache-control') === 'private, no-store',
      `HTTP ${doc.status}, ${doc.headers.get('content-type')}, ${docBuf.length} B; ${doc.headers.get('content-disposition')?.split(';')[0]}`,
    );
    const replay = await call(path);
    await replay.text();
    check('the same link does not work a second time', replay.status === 401 && !(replay.headers.getSetCookie?.() ?? []).length, `HTTP ${replay.status}`);
    if (otherRow) {
      const cross = await call(`/d/${otherRow.id}`, { headers: { cookie } });
      await cross.text();
      check("that document's cookie does not open any other file", cross.status === 401, `HTTP ${cross.status}`);
    }
  }
  const strangerLink = await call(`/links/${docRow.id}`, { method: 'POST', headers: auth(outsider) });
  await strangerLink.text();
  check('NON-PARTICIPANT cannot mint a link', strangerLink.status === 404, `HTTP ${strangerLink.status}`);
  const anonLink = await call(`/links/${docRow.id}`, { method: 'POST' });
  await anonLink.text();
  check('anonymous caller cannot mint a link', anonLink.status === 401, `HTTP ${anonLink.status}`);
}

// ── 3. the endpoint is not a proxy ───────────────────────────────────────────

const t = rows[0];
const a0 = participantsOf(t)[0];
for (const path of [
  `/storage/v1/object/public/post-images/chat_attachments/${t.chat_id}/`,
  `/storage/v1/object/authenticated/chat-attachments/${t.chat_id}/${t.id}.jpg`,
  `/storage/v1/object/list/post-images`,
  `/d/../storage/v1/object/list/post-images`,
  `/d/%2e%2e/rest/v1/chats?select=*`,
  `/rest/v1/chat_messages?select=*`,
  `/d/${t.chat_id}%2F${t.id}`,
  `/d/chat-attachments/${t.chat_id}/${t.id}.jpg`,
  `/d/post-images/chat_attachments/${t.chat_id}`,
  `/https://${SB_HOST}/rest/v1/chats`,
  `/d/${t.id}.jpg`,
]) {
  const res = await call(path, { headers: auth(tokens[a0]) });
  const text = await res.text();
  check(`not a proxy: ${path.slice(0, 70)}`, res.status === 404 && !leaks(res, text), `HTTP ${res.status}`);
}

// ── 4. uploads by callers who must be refused (no write can happen) ─────────

const jpeg = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1]);
const upload = (token) =>
  call(`/u/${t.chat_id}/${randomUUID()}`, {
    method: 'PUT',
    headers: { ...(token ? auth(token) : {}), 'content-type': 'image/jpeg', ...(identity === 'local' ? { 'content-length': String(jpeg.length) } : {}) },
    body: jpeg,
    duplex: 'half',
  });
const anonUp = await upload(null);
await anonUp.text();
check('anonymous caller cannot upload', anonUp.status === 401, `HTTP ${anonUp.status}`);
const strangerUp = await upload(outsider);
await strangerUp.text();
check("NON-PARTICIPANT cannot upload into someone else's chat", strangerUp.status === 404, `HTTP ${strangerUp.status}`);

// ── 5. what storage itself exposes to the app's publishable key ─────────────

const cfg = readFileSync(resolve(REPO_ROOT, 'mobile-app/lib/config/supabase_config.dart'), 'utf8');
const anonKey = /supabaseAnonKey = '([^']+)'/.exec(cfg)?.[1];
const anonHeaders = { apikey: anonKey, ...(anonKey?.startsWith('eyJ') ? { authorization: `Bearer ${anonKey}` } : {}), 'content-type': 'application/json' };
const list = (bucket, prefix) =>
  fetch(`${SB}/storage/v1/object/list/${bucket}`, { method: 'POST', headers: anonHeaders, body: JSON.stringify({ prefix, limit: 100 }) });

const privList = await list('chat-attachments', '');
const privBody = await privList.text();
let privEntries = [];
try {
  privEntries = JSON.parse(privBody);
} catch {
  // Not JSON.
}
check(
  'publishable key cannot list the private chat-attachments bucket',
  !privList.ok || (Array.isArray(privEntries) && privEntries.length === 0),
  `HTTP ${privList.status}, ${Array.isArray(privEntries) ? `${privEntries.length} entries` : 'refused'}`,
);
for (const row of rows.slice(0, 3)) {
  const pub = await fetch(`${SB}/storage/v1/object/public/chat-attachments/${row.chat_id}/${row.id}.${expected.get(row.id)?.ext ?? 'jpg'}`);
  await pub.body?.cancel();
  check(`no public URL exists for ${short(row.id)} in the private bucket`, pub.status >= 400, `HTTP ${pub.status}`);
}
const legacyList = await list('post-images', 'chat_attachments/');
const legacyEntries = legacyList.ok ? await legacyList.json() : [];
note(
  'LEGACY exposure (closes only when old objects are deleted): publishable key lists post-images/chat_attachments/',
  `HTTP ${legacyList.status}, ${Array.isArray(legacyEntries) ? legacyEntries.length : 0} chat folders visible`,
);

// ── report ───────────────────────────────────────────────────────────────────

const failed = results.filter((r) => r.pass === false);
const passed = results.filter((r) => r.pass === true);
console.log(`\n${passed.length} passed, ${failed.length} failed, ${results.length - passed.length - failed.length} informational`);
const dir = resolve(here, '../reports');
mkdirSync(dir, { recursive: true });
const file = resolve(dir, `live-security-${identity}-${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
writeFileSync(file, JSON.stringify({ identity, base: base ?? 'in-process', at: new Date().toISOString(), results }, null, 2));
console.log(`report: ${file}`);
process.exit(failed.length ? 1 : 0);
