import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BYTES, ORIGIN, SUPABASE_URL, assertNoLeak, countingLimiter, exposed, harness, makeSigner, claimsFor, req } from './helpers.js';
import { b64urlDecode } from '../src/tokens.js';

const ALICE = 'uid_alice';
const BOB = 'uid_bob';
const CAROL = 'uid_carol';
const DAVE = 'uid_dave';

const CHAT_AB = 'aaaaaaaa-0000-4000-8000-000000000001';
const CHAT_CD = 'cccccccc-0000-4000-8000-000000000002';

const M = {
  img: 'a1000000-0000-4000-8000-000000000001',
  pdf: 'a2000000-0000-4000-8000-000000000002',
  docx: 'a3000000-0000-4000-8000-000000000003',
  deleted: 'a4000000-0000-4000-8000-000000000004',
  pointsAtOtherChat: 'a5000000-0000-4000-8000-000000000005',
  pointsAtOtherMessage: 'a6000000-0000-4000-8000-000000000006',
  legacy: 'a7000000-0000-4000-8000-000000000007',
  legacyOtherFolder: 'a8000000-0000-4000-8000-000000000008',
  legacyForeignHost: 'a9000000-0000-4000-8000-000000000009',
  text: 'aa000000-0000-4000-8000-00000000000a',
  missingObject: 'ab000000-0000-4000-8000-00000000000b',
  badName: 'ac000000-0000-4000-8000-00000000000c',
  cd: 'c1000000-0000-4000-8000-000000000001',
  nonexistent: 'ffffffff-0000-4000-8000-0000000000ff',
};
const LEGACY_FILE = '0e0e0e0e-0000-4000-8000-000000000e0e';
const LEGACY_PUBLIC = `${SUPABASE_URL}/storage/v1/object/public/post-images/chat_attachments`;

async function setup(opts) {
  const h = await harness(opts);
  const { db } = h;
  db.addChat(CHAT_AB, ALICE, BOB);
  db.addChat(CHAT_CD, CAROL, DAVE);
  const msg = (id, extra) => db.addMessage({ id, chat_id: CHAT_AB, sender_id: ALICE, ...extra });

  msg(M.img, { type: 'image', content: 'Image', attachment_url: `chat-attachments/${CHAT_AB}/${M.img}.jpg` });
  db.putObject('chat-attachments', `${CHAT_AB}/${ALICE}/${M.img}.jpg`, BYTES.jpg);

  msg(M.pdf, { type: 'file', content: 'Contract (final).pdf', attachment_url: `chat-attachments/${CHAT_AB}/${M.pdf}.pdf` });
  db.putObject('chat-attachments', `${CHAT_AB}/${ALICE}/${M.pdf}.pdf`, BYTES.pdf);

  msg(M.docx, { type: 'file', content: 'Quote.docx', attachment_url: `chat-attachments/${CHAT_AB}/${M.docx}.docx` });
  db.putObject('chat-attachments', `${CHAT_AB}/${ALICE}/${M.docx}.docx`, BYTES.docx);

  msg(M.deleted, {
    type: 'image',
    content: 'Image',
    attachment_url: `chat-attachments/${CHAT_AB}/${M.deleted}.jpg`,
    deleted_for_everyone: true,
  });
  db.putObject('chat-attachments', `${CHAT_AB}/${ALICE}/${M.deleted}.jpg`, BYTES.jpg);

  // Carol and Dave's private photo.
  db.addMessage({ id: M.cd, chat_id: CHAT_CD, sender_id: CAROL, type: 'image', content: 'Image', attachment_url: `chat-attachments/${CHAT_CD}/${M.cd}.jpg` });
  db.putObject('chat-attachments', `${CHAT_CD}/${CAROL}/${M.cd}.jpg`, [...BYTES.jpg, 0x99]);

  // A row in Alice's chat whose stored reference names Carol and Dave's file.
  msg(M.pointsAtOtherChat, { type: 'image', content: 'Image', attachment_url: `chat-attachments/${CHAT_CD}/${M.cd}.jpg` });
  // …and one naming a different message's file in the same chat.
  msg(M.pointsAtOtherMessage, { type: 'image', content: 'Image', attachment_url: `chat-attachments/${CHAT_AB}/${M.img}.jpg` });

  msg(M.legacy, { type: 'image', content: 'Image', attachment_url: `${LEGACY_PUBLIC}/${CHAT_AB}/${LEGACY_FILE}.jpg` });
  db.putObject('post-images', `chat_attachments/${CHAT_AB}/${LEGACY_FILE}.jpg`, BYTES.jpg);
  msg(M.legacyOtherFolder, { type: 'image', content: 'Image', attachment_url: `${LEGACY_PUBLIC}/${CHAT_CD}/${LEGACY_FILE}.jpg` });
  db.putObject('post-images', `chat_attachments/${CHAT_CD}/${LEGACY_FILE}.jpg`, BYTES.jpg);
  msg(M.legacyForeignHost, {
    type: 'image',
    content: 'Image',
    attachment_url: `https://evil.example/storage/v1/object/public/post-images/chat_attachments/${CHAT_AB}/${LEGACY_FILE}.jpg`,
  });

  msg(M.text, { type: 'text', content: 'hello', attachment_url: `chat-attachments/${CHAT_AB}/${M.text}.jpg` });
  msg(M.missingObject, { type: 'image', content: 'Image', attachment_url: `chat-attachments/${CHAT_AB}/${M.missingObject}.jpg` });
  msg(M.badName, {
    type: 'file',
    content: 'evil"\r\nSet-Cookie: pwn=1;.pdf',
    attachment_url: `chat-attachments/${CHAT_AB}/${M.badName}.pdf`,
  });
  db.putObject('chat-attachments', `${CHAT_AB}/${ALICE}/${M.badName}.pdf`, BYTES.pdf);

  const tokens = {
    alice: await h.tokenFor(ALICE),
    bob: await h.tokenFor(BOB),
    carol: await h.tokenFor(CAROL),
  };
  return { ...h, tokens };
}

const bytesOf = async (res) => [...new Uint8Array(await res.arrayBuffer())];

// ═══ Reading a file ═══════════════════════════════════════════════════════════

test('a participant gets their photo, typed and named by the Worker, through the Help24 host', async () => {
  const { app, db, tokens } = await setup();
  const res = await app.fetch(req(`/d/${M.img}`, { token: tokens.alice }));
  assertNoLeak(assert, await exposed(res));
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'image/jpeg');
  assert.equal(res.headers.get('content-disposition'), `inline; filename="help24-photo-a1000000.jpg"; filename*=UTF-8''help24-photo-a1000000.jpg`);
  assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
  assert.match(res.headers.get('content-security-policy'), /sandbox/);
  assert.equal(res.headers.get('cache-control'), 'private, max-age=604800');
  assert.deepEqual(await bytesOf(res), BYTES.jpg);
  // Exactly two upstream calls: the row, then that row's own object.
  assert.deepEqual(
    db.calls.map((c) => `${c.method} ${c.path}`),
    ['GET /rest/v1/chat_messages', `GET /storage/v1/object/authenticated/chat-attachments/${CHAT_AB}/${ALICE}/${M.img}.jpg`],
  );
});

test('the other participant can read it too', async () => {
  const { app, tokens } = await setup();
  const res = await app.fetch(req(`/d/${M.img}`, { token: tokens.bob }));
  assert.equal(res.status, 200);
  assert.deepEqual(await bytesOf(res), BYTES.jpg);
});

test("a non-participant cannot retrieve another chat's attachment — and learns nothing", async () => {
  const { app, db, tokens } = await setup();
  const stranger = await app.fetch(req(`/d/${M.img}`, { token: tokens.carol }));
  const missing = await app.fetch(req(`/d/${M.nonexistent}`, { token: tokens.carol }));
  assert.equal(stranger.status, 404);
  assert.equal(missing.status, 404);
  // Identical answer for "not yours" and "does not exist": no existence oracle.
  assert.equal(await stranger.text(), await missing.text());
  assert.deepEqual([...stranger.headers.entries()], [...missing.headers.entries()]);
  assert.equal(db.objectCalls().length, 0, 'no storage read happened for a stranger');
});

test('a non-participant is refused even for a deleted message (no deletion oracle)', async () => {
  const { app, tokens } = await setup();
  const res = await app.fetch(req(`/d/${M.deleted}`, { token: tokens.carol }));
  assert.equal(res.status, 404);
});

test('no credentials: refused before anything is looked up', async () => {
  const { app, db } = await setup();
  const res = await app.fetch(req(`/d/${M.img}`));
  assert.equal(res.status, 401);
  assert.match(res.headers.get('content-type'), /text\/html/);
  assertNoLeak(assert, await exposed(res));
  assert.equal(db.calls.length, 0);
});

test('forged, malformed and foreign tokens are refused', async () => {
  const { app, db, signer, clock } = await setup();
  const otherKey = await makeSigner(signer.kid); // same kid, different key
  const cases = {
    garbage: 'not-a-token',
    'signed by another key': await otherKey.sign(claimsFor(ALICE, clock.ms)),
    'alg none': `${Buffer.from('{"alg":"none","kid":"kid-1"}').toString('base64url')}.${Buffer.from(JSON.stringify(claimsFor(ALICE, clock.ms))).toString('base64url')}.`,
    'HS256 header': await signer.sign(claimsFor(ALICE, clock.ms), { alg: 'HS256' }),
    'other project (aud)': await signer.sign(claimsFor(ALICE, clock.ms, { aud: 'someone-else' })),
    'other issuer': await signer.sign(claimsFor(ALICE, clock.ms, { iss: 'https://securetoken.google.com/someone-else' })),
    'empty subject': await signer.sign(claimsFor('', clock.ms)),
    'issued in the future': await signer.sign(claimsFor(ALICE, clock.ms, { iat: Math.floor(clock.ms / 1000) + 3600 })),
  };
  for (const [name, token] of Object.entries(cases)) {
    const res = await app.fetch(req(`/d/${M.img}`, { token }));
    assert.equal(res.status, 401, name);
    assert.deepEqual(await res.json(), { code: 'UNAUTHENTICATED' }, name);
  }
  // A tampered payload (uid swapped to Alice's on a token signed for Carol).
  const carol = await signer.sign(claimsFor(CAROL, clock.ms));
  const [h, , s] = carol.split('.');
  const swapped = `${h}.${Buffer.from(JSON.stringify(claimsFor(ALICE, clock.ms))).toString('base64url')}.${s}`;
  assert.equal((await app.fetch(req(`/d/${M.img}`, { token: swapped }))).status, 401);
  assert.equal(db.objectCalls().length, 0);
});

test('an expired Firebase token answers TOKEN_EXPIRED, the code the app refreshes on', async () => {
  const { app, tokenFor, clock } = await setup();
  const token = await tokenFor(ALICE, { exp: Math.floor(clock.ms / 1000) - 1 });
  const res = await app.fetch(req(`/d/${M.img}`, { token }));
  assert.equal(res.status, 401);
  assert.deepEqual(await res.json(), { code: 'TOKEN_EXPIRED' });
});

test('Google keys unreachable is 503, never a 401 that would sign people out', async () => {
  const { app, jwks, tokens } = await setup();
  jwks.fail = true;
  const res = await app.fetch(req(`/d/${M.img}`, { token: tokens.alice }));
  assert.equal(res.status, 503);
});

test('deleted for everyone: 410 for participants, and the bytes are never fetched', async () => {
  const { app, db, tokens } = await setup();
  for (const token of [tokens.alice, tokens.bob]) {
    const res = await app.fetch(req(`/d/${M.deleted}`, { token }));
    assert.equal(res.status, 410);
    assert.deepEqual(await res.json(), { code: 'GONE' });
  }
  assert.equal(db.objectCalls().length, 0);
});

test("a row whose reference names someone else's file serves nothing", async () => {
  const { app, db, tokens } = await setup();
  for (const id of [M.pointsAtOtherChat, M.pointsAtOtherMessage, M.legacyOtherFolder, M.legacyForeignHost, M.text]) {
    const res = await app.fetch(req(`/d/${id}`, { token: tokens.alice }));
    assert.equal(res.status, 404, id);
  }
  assert.equal(db.objectCalls().length, 0, 'the referenced object was never even requested');
});

test("a legacy public-bucket attachment is served only from its own chat's folder", async () => {
  const { app, db, tokens } = await setup();
  const res = await app.fetch(req(`/d/${M.legacy}`, { token: tokens.bob }));
  assertNoLeak(assert, await exposed(res));
  assert.equal(res.status, 200);
  assert.deepEqual(await bytesOf(res), BYTES.jpg);
  assert.deepEqual(db.objectCalls().map((c) => c.path), [
    `/storage/v1/object/authenticated/post-images/chat_attachments/${CHAT_AB}/${LEGACY_FILE}.jpg`,
  ]);
});

test('no path or query reaches storage except a message’s own object', async () => {
  const { app, db, tokens } = await setup();
  const hostile = [
    `/d/../storage/v1/object/authenticated/chat-attachments/${CHAT_CD}/${M.cd}.jpg`,
    `/storage/v1/object/public/post-images/chat_attachments/${CHAT_CD}/${LEGACY_FILE}.jpg`,
    `/storage/v1/object/list/post-images`,
    `/d/${M.img}/../../rest/v1/chats`,
    `/d/%2e%2e/%2e%2e/rest/v1/chats?select=*`,
    `/d/${CHAT_CD}%2F${M.cd}.jpg`,
    `/d/chat-attachments/${CHAT_CD}/${M.cd}.jpg`,
    `/d/${M.cd}.jpg`,
    `/d/${M.cd}/`,
    `/d/${M.cd}%00`,
    `//projref.supabase.co/storage/v1/object/authenticated/chat-attachments/${CHAT_CD}/${M.cd}.jpg`,
    `/https://projref.supabase.co/rest/v1/chats`,
    `/u/${CHAT_CD}/${M.cd}/../../d/${M.cd}`,
    `/links/${M.cd}/../../d/${M.cd}`,
    `/rest/v1/chat_messages?select=*`,
    `/`,
  ];
  for (const path of hostile) {
    const res = await app.fetch(req(path, { token: tokens.alice }));
    assertNoLeak(assert, await exposed(res));
    assert.equal(res.status, 404, path);
  }
  // Some of these normalise to a real `/d/<id>` for a message Alice is not in:
  // that costs one row lookup and nothing more. Storage is never touched.
  assert.equal(db.objectCalls().length, 0, `storage was called: ${JSON.stringify(db.objectCalls().map((c) => c.path))}`);
  for (const call of db.calls) {
    assert.equal(`${call.method} ${call.path}`, 'GET /rest/v1/chat_messages');
    assert.match(call.search, /&id=eq\.[0-9a-f-]{36}&limit=1$/);
  }

  // Query parameters are never a pointer: this is still Alice's own photo.
  const res = await app.fetch(req(`/d/${M.img}?bucket=post-images&key=chat_attachments/${CHAT_CD}/x.jpg&path=../`, { token: tokens.alice }));
  assert.equal(res.status, 200);
  assert.deepEqual(db.objectCalls().map((c) => c.path), [`/storage/v1/object/authenticated/chat-attachments/${CHAT_AB}/${ALICE}/${M.img}.jpg`]);
});

test('wrong methods are refused', async () => {
  const { app, tokens } = await setup();
  assert.equal((await app.fetch(req(`/d/${M.img}`, { method: 'PUT', token: tokens.alice, body: 'x' }))).status, 405);
  assert.equal((await app.fetch(req(`/d/${M.img}`, { method: 'DELETE', token: tokens.alice }))).status, 405);
  assert.equal((await app.fetch(req(`/links/${M.img}`, { token: tokens.alice }))).status, 405);
  assert.equal((await app.fetch(req(`/u/${CHAT_AB}/${M.img}`, { method: 'POST', token: tokens.alice, body: 'x' }))).status, 405);
});

test('range requests pass through as 206', async () => {
  const { app, tokens } = await setup();
  const res = await app.fetch(req(`/d/${M.pdf}`, { token: tokens.alice, headers: { range: 'bytes=0-3' } }));
  assert.equal(res.status, 206);
  assert.equal(res.headers.get('content-range'), `bytes 0-3/${BYTES.pdf.length}`);
  assert.deepEqual(await bytesOf(res), BYTES.pdf.slice(0, 4));
  const unsatisfiable = await app.fetch(req(`/d/${M.pdf}`, { token: tokens.alice, headers: { range: 'bytes=99999-' } }));
  assert.equal(unsatisfiable.status, 416);
});

test('a multi-range or malformed Range is ignored, not forwarded', async () => {
  const { app, db, tokens } = await setup();
  const res = await app.fetch(req(`/d/${M.pdf}`, { token: tokens.alice, headers: { range: 'bytes=0-1,5-9' } }));
  assert.equal(res.status, 200);
  assert.equal(db.objectCalls()[0].headers.get('range'), null);
});

test('HEAD answers headers and no body', async () => {
  const { app, tokens } = await setup();
  const res = await app.fetch(req(`/d/${M.img}`, { method: 'HEAD', token: tokens.alice }));
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-length'), String(BYTES.jpg.length));
  assert.equal(res.body, null);
});

test('the app revalidates with If-None-Match and gets 304', async () => {
  const { app, tokens } = await setup();
  const first = await app.fetch(req(`/d/${M.img}`, { token: tokens.alice }));
  const etag = first.headers.get('etag');
  assert.ok(etag);
  const again = await app.fetch(req(`/d/${M.img}`, { token: tokens.alice, headers: { 'if-none-match': etag } }));
  assert.equal(again.status, 304);
});

test('a PDF opens inline under the name it was sent with', async () => {
  const { app, tokens } = await setup();
  const res = await app.fetch(req(`/d/${M.pdf}`, { token: tokens.alice }));
  assert.equal(res.headers.get('content-type'), 'application/pdf');
  assert.equal(
    res.headers.get('content-disposition'),
    `inline; filename="Contract (final).pdf"; filename*=UTF-8''Contract%20%28final%29.pdf`,
  );
  // Chrome's PDF viewer must be allowed to render it.
  assert.equal(res.headers.get('content-security-policy'), null);
});

test('a Word document downloads as an attachment under its own name', async () => {
  const { app, tokens } = await setup();
  const res = await app.fetch(req(`/d/${M.docx}`, { token: tokens.alice }));
  assert.equal(res.headers.get('content-type'), 'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
  assert.match(res.headers.get('content-disposition'), /^attachment; filename="Quote\.docx"/);
});

test('a hostile file name cannot inject headers', async () => {
  const { app, tokens } = await setup();
  const res = await app.fetch(req(`/d/${M.badName}`, { token: tokens.alice }));
  assert.equal(res.status, 200);
  const cd = res.headers.get('content-disposition');
  assert.ok(!/[\r\n]/.test(cd), cd);
  assert.equal(res.headers.get('set-cookie'), null);
  assert.equal(cd, `inline; filename="evil Set-Cookie pwn=1.pdf"; filename*=UTF-8''evil%20Set-Cookie%20pwn%3D1.pdf`);
});

test('a row whose object is missing is a plain 404', async () => {
  const { app, tokens } = await setup();
  const res = await app.fetch(req(`/d/${M.missingObject}`, { token: tokens.alice }));
  assertNoLeak(assert, await exposed(res));
  assert.equal(res.status, 404);
});

test('an upstream failure is a bare 503 — no status, body or hostname from Supabase', async () => {
  const { app, db, tokens, events } = await setup();
  db.failWith = 500;
  const res = await app.fetch(req(`/d/${M.img}`, { token: tokens.alice }));
  assertNoLeak(assert, await exposed(res));
  assert.equal(res.status, 503);
  assert.deepEqual(await res.json(), { code: 'UNAVAILABLE' });
  assert.ok(events.some((e) => e.event === 'error' && e.kind === 'upstream'));
});

// ═══ Opening a document in the browser ═══════════════════════════════════════

async function openInBrowser(app, token, id) {
  const minted = await app.fetch(req(`/links/${id}`, { method: 'POST', token }));
  assert.equal(minted.status, 200);
  const { url, expires_in } = await minted.json();
  return { url, expires_in };
}

function cookieFrom(res) {
  const header = res.headers.get('set-cookie');
  assert.ok(header, 'expected a cookie');
  return header.split(';')[0];
}

test('link → cookie → document: the browser flow, end to end', async () => {
  const { app, tokens } = await setup();
  const { url, expires_in } = await openInBrowser(app, tokens.alice, M.pdf);
  assert.equal(expires_in, 120);
  const parsed = new URL(url);
  assert.equal(parsed.origin, ORIGIN);
  assert.equal(parsed.pathname, `/d/${M.pdf}`);
  assert.ok(parsed.searchParams.get('t'));

  const exchange = await app.fetch(new Request(url));
  assert.equal(exchange.status, 303);
  assert.equal(exchange.headers.get('location'), `/d/${M.pdf}`, 'the token is stripped from the address bar');
  const setCookie = exchange.headers.get('set-cookie');
  assert.match(setCookie, new RegExp(`; Path=/d/${M.pdf}; Max-Age=600; HttpOnly; Secure; SameSite=Lax$`));
  assertNoLeak(assert, await exposed(exchange));

  const doc = await app.fetch(req(`/d/${M.pdf}`, { headers: { cookie: cookieFrom(exchange) } }));
  assert.equal(doc.status, 200);
  assert.equal(doc.headers.get('content-type'), 'application/pdf');
  assert.equal(doc.headers.get('cache-control'), 'private, no-store');
  assert.deepEqual(await bytesOf(doc), BYTES.pdf);
});

test('a link works exactly once', async () => {
  const { app, tokens, events } = await setup();
  const { url } = await openInBrowser(app, tokens.alice, M.pdf);
  assert.equal((await app.fetch(new Request(url))).status, 303);
  const replay = await app.fetch(new Request(url));
  assert.equal(replay.status, 401);
  assert.equal(replay.headers.get('set-cookie'), null);
  assert.ok(events.some((e) => e.event === 'link_replayed'));
});

test('HEAD on a link does not burn it', async () => {
  const { app, tokens } = await setup();
  const { url } = await openInBrowser(app, tokens.alice, M.pdf);
  assert.equal((await app.fetch(new Request(url, { method: 'HEAD' }))).status, 405);
  assert.equal((await app.fetch(new Request(url))).status, 303);
});

test('a link expires after two minutes', async () => {
  const { app, tokens, clock } = await setup();
  const { url } = await openInBrowser(app, tokens.alice, M.pdf);
  clock.ms += 121_000;
  const res = await app.fetch(new Request(url));
  assert.equal(res.status, 401);
  assert.equal(res.headers.get('set-cookie'), null);
});

test('a link names one document and cannot be pointed at another', async () => {
  const { app, tokens } = await setup();
  const { url } = await openInBrowser(app, tokens.alice, M.pdf);
  const t = new URL(url).searchParams.get('t');
  for (const id of [M.img, M.cd]) {
    const res = await app.fetch(new Request(`${ORIGIN}/d/${id}?t=${t}`));
    assert.equal(res.status, 401, id);
    assert.equal(res.headers.get('set-cookie'), null);
  }
});

test('strangers, anonymous callers and deleted messages get no link', async () => {
  const { app, db, tokens } = await setup();
  assert.equal((await app.fetch(req(`/links/${M.pdf}`, { method: 'POST', token: tokens.carol }))).status, 404);
  assert.equal((await app.fetch(req(`/links/${M.pdf}`, { method: 'POST' }))).status, 401);
  assert.equal((await app.fetch(req(`/links/${M.deleted}`, { method: 'POST', token: tokens.alice }))).status, 410);
  assert.equal((await app.fetch(req(`/links/${M.nonexistent}`, { method: 'POST', token: tokens.alice }))).status, 404);
  assert.equal(db.objectCalls().length, 0);
});

test('a document cookie opens only its own document, and only for ten minutes', async () => {
  const { app, tokens, clock } = await setup();
  const { url } = await openInBrowser(app, tokens.alice, M.pdf);
  const cookie = cookieFrom(await app.fetch(new Request(url)));
  assert.equal((await app.fetch(req(`/d/${M.img}`, { headers: { cookie } }))).status, 401);
  assert.equal((await app.fetch(req(`/d/${M.cd}`, { headers: { cookie } }))).status, 401);
  clock.ms += 601_000;
  assert.equal((await app.fetch(req(`/d/${M.pdf}`, { headers: { cookie } }))).status, 401);
});

test('tampered links and cookies are refused', async () => {
  const { app, tokens } = await setup();
  const { url } = await openInBrowser(app, tokens.alice, M.pdf);
  const t = new URL(url).searchParams.get('t');
  const flip = (s, i) => s.slice(0, i) + (s[i] === 'A' ? 'B' : 'A') + s.slice(i + 1);
  for (const bad of [flip(t, 3), flip(t, t.length - 3), `${t}x`, t.split('.')[0], `${t.split('.')[0]}.`]) {
    assert.equal((await app.fetch(new Request(`${ORIGIN}/d/${M.pdf}?t=${bad}`))).status, 401);
  }
  const cookie = cookieFrom(await app.fetch(new Request(url)));
  const value = cookie.split('=')[1];
  assert.equal((await app.fetch(req(`/d/${M.pdf}`, { headers: { cookie: `h24doc=${flip(value, 5)}` } }))).status, 401);
});

test('a link cannot be used as a cookie, nor a cookie as a link', async () => {
  const { app, tokens } = await setup();
  const { url } = await openInBrowser(app, tokens.alice, M.pdf);
  const t = new URL(url).searchParams.get('t');
  assert.equal((await app.fetch(req(`/d/${M.pdf}`, { headers: { cookie: `h24doc=${t}` } }))).status, 401);
  const cookieValue = cookieFrom(await app.fetch(new Request(url))).split('=')[1];
  assert.equal((await app.fetch(new Request(`${ORIGIN}/d/${M.pdf}?t=${cookieValue}`))).status, 401);
});

test('deleting the message kills an outstanding link and an open cookie', async () => {
  const { app, db, tokens } = await setup();
  const first = await openInBrowser(app, tokens.alice, M.pdf);
  const cookie = cookieFrom(await app.fetch(new Request(first.url)));
  const second = await openInBrowser(app, tokens.alice, M.pdf);

  db.messages.get(M.pdf).deleted_for_everyone = true;
  assert.equal((await app.fetch(new Request(second.url))).status, 410);
  assert.equal((await app.fetch(req(`/d/${M.pdf}`, { headers: { cookie } }))).status, 410);
});

test('losing membership of the chat revokes a link and a cookie', async () => {
  const { app, db, tokens } = await setup();
  const first = await openInBrowser(app, tokens.bob, M.pdf);
  const cookie = cookieFrom(await app.fetch(new Request(first.url)));
  const pending = await openInBrowser(app, tokens.bob, M.pdf);

  db.chats.set(CHAT_AB, { user1: ALICE, user2: DAVE });
  assert.equal((await app.fetch(req(`/d/${M.pdf}`, { headers: { cookie } }))).status, 404);
  assert.equal((await app.fetch(new Request(pending.url))).status, 404);
});

test('links and cookies never carry the user id', async () => {
  const { app, tokens } = await setup();
  const { url } = await openInBrowser(app, tokens.alice, M.pdf);
  const t = new URL(url).searchParams.get('t');
  const cookie = cookieFrom(await app.fetch(new Request(url))).split('=')[1];
  for (const token of [t, cookie]) {
    const payload = new TextDecoder().decode(b64urlDecode(token.split('.')[0]));
    assert.ok(!payload.includes(ALICE), payload);
    assert.ok(!payload.includes('alice'), payload);
  }
});

// ═══ Uploading ════════════════════════════════════════════════════════════════

const NEW_ID = 'b1000000-0000-4000-8000-0000000000b1';

function put(chat, id, { token, type = 'image/jpeg', bytes = BYTES.jpg, length } = {}) {
  const body = Uint8Array.from(bytes);
  return req(`/u/${chat}/${id}`, {
    method: 'PUT',
    token,
    headers: { 'content-type': type, 'content-length': String(length ?? body.length) },
    body,
  });
}

test("a participant's upload lands in the private bucket under its message's own key", async () => {
  const { app, db, tokens } = await setup();
  const res = await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.bob }));
  assertNoLeak(assert, await exposed(res));
  assert.equal(res.status, 201);
  assert.deepEqual(await res.json(), { ref: `chat-attachments/${CHAT_AB}/${NEW_ID}.jpg`, stored: true });
  const stored = db.objects.get(`chat-attachments/${CHAT_AB}/${BOB}/${NEW_ID}.jpg`);
  assert.deepEqual([...stored.bytes], BYTES.jpg);
  assert.equal(stored.contentType, 'image/jpeg');
});

test('a retried upload is answered "already stored" and never overwrites', async () => {
  const { app, db, tokens } = await setup();
  assert.equal((await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.alice }))).status, 201);
  const retry = await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.alice, bytes: [...BYTES.jpg, 1, 2, 3] }));
  assert.equal(retry.status, 200);
  assert.deepEqual(await retry.json(), { ref: `chat-attachments/${CHAT_AB}/${NEW_ID}.jpg`, stored: false });
  assert.deepEqual([...db.objects.get(`chat-attachments/${CHAT_AB}/${ALICE}/${NEW_ID}.jpg`).bytes], BYTES.jpg);
});

test("a stranger cannot upload into someone else's chat", async () => {
  const { app, db, tokens } = await setup();
  const res = await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.carol }));
  assert.equal(res.status, 404);
  assert.equal(db.calls.filter((c) => c.method === 'POST').length, 0);
  const anon = await app.fetch(put(CHAT_AB, NEW_ID, {}));
  assert.equal(anon.status, 401);
  assert.equal(db.calls.filter((c) => c.method === 'POST').length, 0);
});

test('an upload into a chat that does not exist is refused', async () => {
  const { app, tokens } = await setup();
  const res = await app.fetch(put('dddddddd-0000-4000-8000-000000000000', NEW_ID, { token: tokens.alice }));
  assert.equal(res.status, 404);
});

test('content that is not what it claims to be is refused', async () => {
  const { app, db, tokens } = await setup();
  const html = await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.alice, bytes: BYTES.html }));
  assert.equal(html.status, 415);
  assert.deepEqual(await html.json(), { code: 'CONTENT_MISMATCH' });
  for (const type of ['text/html', 'application/octet-stream', 'image/svg+xml', 'application/javascript', '']) {
    const res = await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.alice, type, bytes: BYTES.html }));
    assert.equal(res.status, 415, type);
  }
  // A PDF declared as a JPEG is refused too: the type decides the stored key.
  assert.equal((await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.alice, bytes: BYTES.pdf }))).status, 415);
  assert.equal(db.calls.filter((c) => c.method === 'POST').length, 0);
});

test('size limits: 10 MB declared ceiling, and the body must match its declaration', async () => {
  const { app, db, tokens } = await setup();
  const big = await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.alice, length: 10 * 1024 * 1024 + 1 }));
  assert.equal(big.status, 413);
  const lying = await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.alice, length: 4 }));
  assert.equal(lying.status, 400);
  const empty = await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.alice, bytes: [] }));
  assert.equal(empty.status, 400);
  assert.equal(db.calls.filter((c) => c.method === 'POST').length, 0);
});

test('a body larger than 10 MB is cut off even when it claims to be small', async () => {
  const { app, tokens } = await setup();
  const huge = new Uint8Array(10 * 1024 * 1024 + 10);
  huge.set(BYTES.jpg);
  const res = await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.alice, bytes: huge, length: 1000 }));
  assert.equal(res.status, 413);
});

test('ids are normalised to lower case in the stored key', async () => {
  const { app, db, tokens } = await setup();
  const res = await app.fetch(put(CHAT_AB.toUpperCase(), NEW_ID.toUpperCase(), { token: tokens.alice, type: 'application/pdf', bytes: BYTES.pdf }));
  assert.equal(res.status, 201);
  assert.ok(db.objects.has(`chat-attachments/${CHAT_AB}/${ALICE}/${NEW_ID}.pdf`));
});

test('an uploaded file is readable through /d once its message row exists — and only then', async () => {
  const { app, db, tokens } = await setup();
  await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.alice, type: 'application/pdf', bytes: BYTES.pdf }));
  assert.equal((await app.fetch(req(`/d/${NEW_ID}`, { token: tokens.bob }))).status, 404);
  db.addMessage({ id: NEW_ID, chat_id: CHAT_AB, sender_id: ALICE, type: 'file', content: 'Plan.pdf', attachment_url: `chat-attachments/${CHAT_AB}/${NEW_ID}.pdf` });
  const res = await app.fetch(req(`/d/${NEW_ID}`, { token: tokens.bob }));
  assert.equal(res.status, 200);
  assert.deepEqual(await bytesOf(res), BYTES.pdf);
  assert.equal((await app.fetch(req(`/d/${NEW_ID}`, { token: tokens.carol }))).status, 404);
});

test('logs never contain a token, a uid or a full message id', async () => {
  const { app, tokens, events } = await setup();
  const { url } = await openInBrowser(app, tokens.alice, M.pdf);
  await app.fetch(new Request(url));
  await app.fetch(new Request(url));
  await app.fetch(req(`/d/${M.img}`, { token: tokens.carol }));
  await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.alice }));
  const text = JSON.stringify(events);
  const t = new URL(url).searchParams.get('t');
  for (const secret of [tokens.alice, tokens.carol, t, ALICE, CAROL, M.pdf, M.img, CHAT_AB]) {
    assert.ok(!text.includes(secret), `log contains ${secret.slice(0, 12)}…`);
  }
});

// ═══ One participant cannot pass a file off as the other's ════════════════════
// chat_messages RLS lets either participant insert or edit a row with ANY
// sender_id in their chat. The file a row serves is therefore bound to the
// row's SENDER: it is read from the uploader's own folder.

test("a file Bob uploads is never served as a message from Alice", async () => {
  const { app, db, tokens } = await setup();
  assert.equal((await app.fetch(put(CHAT_AB, NEW_ID, { token: tokens.bob, type: 'application/pdf', bytes: BYTES.pdf }))).status, 201);
  // Bob writes the row claiming Alice sent it (RLS allows that).
  db.addMessage({ id: NEW_ID, chat_id: CHAT_AB, sender_id: ALICE, type: 'file', content: 'Signed contract.pdf', attachment_url: `chat-attachments/${CHAT_AB}/${NEW_ID}.pdf` });
  for (const token of [tokens.alice, tokens.bob]) {
    assert.equal((await app.fetch(req(`/d/${NEW_ID}`, { token }))).status, 404);
  }
  // As Bob's own message, it is his file and it is served.
  db.messages.get(NEW_ID).sender_id = BOB;
  assert.equal((await app.fetch(req(`/d/${NEW_ID}`, { token: tokens.alice }))).status, 200);
});

test("re-typing the other person's message to a file of your own serves nothing", async () => {
  const { app, db, tokens } = await setup();
  // Alice's photo M.img. Bob uploads a PDF under the same message id…
  assert.equal((await app.fetch(put(CHAT_AB, M.img, { token: tokens.bob, type: 'application/pdf', bytes: BYTES.pdf }))).status, 201);
  // …and edits Alice's row to point at a .pdf.
  Object.assign(db.messages.get(M.img), { type: 'file', attachment_url: `chat-attachments/${CHAT_AB}/${M.img}.pdf` });
  const res = await app.fetch(req(`/d/${M.img}`, { token: tokens.alice }));
  assert.equal(res.status, 404);
  assert.ok(!db.objectCalls().some((c) => c.method === 'GET' && c.path.includes(`/${BOB}/`)), "Bob's folder is never read for Alice's message");
});

test('a link raced from two places at once opens exactly once', async () => {
  const { app, tokens } = await setup();
  const { url } = await openInBrowser(app, tokens.alice, M.pdf);
  const results = await Promise.all(Array.from({ length: 5 }, () => app.fetch(new Request(url))));
  assert.deepEqual(results.map((r) => r.status).sort(), [303, 401, 401, 401, 401]);
});

test('uploads and browser links are rate-limited per person', async () => {
  const { app, tokens } = await setup({ limits: { upload: countingLimiter(2), link: countingLimiter(2) } });
  const ids = ['b2000000-0000-4000-8000-0000000000b2', 'b3000000-0000-4000-8000-0000000000b3', 'b4000000-0000-4000-8000-0000000000b4'];
  const statuses = [];
  for (const id of ids) statuses.push((await app.fetch(put(CHAT_AB, id, { token: tokens.alice }))).status);
  assert.deepEqual(statuses, [201, 201, 429]);
  // Bob has his own allowance.
  assert.equal((await app.fetch(put(CHAT_AB, ids[2], { token: tokens.bob }))).status, 201);

  const links = [];
  for (let i = 0; i < 3; i++) links.push((await app.fetch(req(`/links/${M.pdf}`, { method: 'POST', token: tokens.alice }))).status);
  assert.deepEqual(links, [200, 200, 429]);
});
