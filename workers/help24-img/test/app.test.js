import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';
import { BYTES, FakeCache, FakeStorage, MINUTE, ORIGIN, SUPABASE_URL, assertOnlyAllowedHeaders, fakeCtx, harness } from './helpers.js';

const ID = '3f2b8c1e-9a4d-4e7b-8c21-5d6e7f8a9b0c';
const ID2 = '7c1d2e3f-4a5b-4c6d-8e7f-90a1b2c3d4e5';
const UID = 'kQ9fZ2xLmN3pR7sT1uV5wY8aB0c2';

const PHOTO = `post-images/posts/${ID}.jpg`;
const THUMB = `post-images/posts/${ID}.thumb.jpg`;
const AVATAR = `profiles/${UID}/avatar.jpg`;
const OLD_AVATAR = `post-images/avatars/${UID}.png`;

const IMMUTABLE_CC = 'public, max-age=31536000, immutable';
const MUTABLE_CC = 'public, max-age=300';

/** "bucket/path" -> [bucket, path] for FakeStorage. */
const split = (full) => {
  const i = full.indexOf('/');
  return [full.slice(0, i), full.slice(i + 1)];
};
const put = (h, full, bytes, opts) => h.storage.put(...split(full), bytes, opts);
const upstreamOf = (full, query = '') => `${SUPABASE_URL}/storage/v1/object/public/${full}${query}`;

/** Nothing that names a person or an object may reach a log line. */
function assertLogsAnonymous(events) {
  const text = JSON.stringify(events);
  for (const needle of [UID, ID, ID2, 'posts/', 'avatar', 'profiles/']) {
    assert.ok(!text.includes(needle), `a log line named "${needle}": ${text}`);
  }
}

// ═══ 1. refused paths never reach Supabase ═════════════════════════════════════

test('private buckets, legacy and test prefixes, unknown buckets and traversal tricks: 404 with zero upstream calls', async () => {
  const h = harness();
  // Real objects behind every refused name, so a leak would succeed if it happened.
  for (const full of [
    `chat-attachments/${ID}/${UID}/${ID2}.jpg`,
    `dispute-evidence/${ID}/${ID2}.jpg`,
    `provider-verifications/${UID}/id-front.jpg`,
    `support-attachments/${ID}/${ID2}.png`,
    `post-images/chat_attachments/${ID}/${ID2}.jpg`,
    `post-images/test/${ID}.jpg`,
    'chat-attachments/x.jpg',
  ]) {
    put(h, full, BYTES.jpg);
  }

  const refused = [
    `/chat-attachments/${ID}/${UID}/${ID2}.jpg`,
    `/dispute-evidence/${ID}/${ID2}.jpg`,
    `/provider-verifications/${UID}/id-front.jpg`,
    `/support-attachments/${ID}/${ID2}.png`,
    // Private buckets wearing a public name's shape.
    `/chat-attachments/posts/${ID}.jpg`,
    `/dispute-evidence/${UID}/avatar.jpg`,
    `/support-attachments/avatars/${UID}.png`,
    `/post-images/chat_attachments/${ID}/${ID2}.jpg`,
    `/post-images/test/${ID}.jpg`,
    '/post-images/test/diagnostic.jpg',
    `/unknown-bucket/posts/${ID}.jpg`,
    `/avatars/${UID}.jpg`,
    `/storage/v1/object/public/post-images/posts/${ID}.jpg`,
    '/',
    '',
    '/post-images',
    '/post-images/',
    `/profiles/${UID}`,
    // Traversal and encoding. The URL parser resolves some of these before
    // the Worker sees them; whatever it leaves must still be refused.
    '/post-images/posts/../../chat-attachments/x.jpg',
    `/post-images/posts/../../chat-attachments/${ID}/${UID}/${ID2}.jpg`,
    `/post-images/posts/%2e%2e/%2e%2e/chat-attachments/${ID}/${UID}/${ID2}.jpg`,
    `/post-images/posts/.%2E/.%2E/chat-attachments/x.jpg`,
    `/post-images/posts/%2e%2e%2f%2e%2e%2fchat-attachments%2fx.jpg`,
    `/post-images/posts%2F${ID}.jpg`,
    `/post-images%2Fposts%2F${ID}.jpg`,
    `/post-images/posts/${ID}%2Ejpg`,
    `/post-images/posts%5C${ID}.jpg`,
    '/post-images\\posts\\..\\..\\chat-attachments\\x.jpg',
    `/post-images/posts\\..\\..\\chat-attachments/${ID}/${UID}/${ID2}.jpg`,
    `/post-images//posts/${ID}.jpg`,
    `//post-images/posts/${ID}.jpg`,
    `/post-images/posts//${ID}.jpg`,
    `/profiles/${UID}/../x`,
    `/profiles/${UID}/../../chat-attachments/x.jpg`,
    `/profiles/${UID}/avatar.jpg%00`,
    // (A trailing control character never arrives: the parser trims it.)
    `/profiles/${UID}/avatar\u0000.jpg`,
    `/profiles/${UID}\u0007/avatar.jpg`,
    `/profiles/ü${UID}/avatar.jpg`,
    `/profiles/${'a'.repeat(300)}/avatar.jpg`,
    // Wrong shapes inside allowed buckets.
    `/post-images/posts/${ID}.svg`,
    `/post-images/posts/${ID}.html`,
    `/post-images/posts/${ID}.jpg/extra`,
    '/post-images/posts/not-a-uuid.jpg',
    `/profiles/${UID}/other.jpg`,
    // A query never rescues a refused path.
    `/chat-attachments/${ID}/${UID}/${ID2}.jpg?t=1`,
  ];

  for (const path of refused) {
    const { status, res, body } = await h.send(path);
    assert.equal(status, 404, path);
    assert.equal(res.headers.get('cache-control'), 'no-store', path);
    assert.equal(res.headers.get('cf-cache-status'), null, path);
    assertOnlyAllowedHeaders(assert, res);
    assert.deepEqual(JSON.parse(new TextDecoder().decode(Uint8Array.from(body))), { code: 'NOT_FOUND' });
  }
  assert.deepEqual(h.storage.calls, [], 'a refused path reached Supabase');
  assert.deepEqual(h.cache.ops, [], 'a refused path touched the cache');
});

// ═══ 2. GET only ══════════════════════════════════════════════════════════════

test('every method but GET is 405 with allow: GET, and nothing goes upstream', async () => {
  const h = harness();
  put(h, PHOTO, BYTES.jpg);
  for (const method of ['POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS']) {
    const { status, res } = await h.send(`/${PHOTO}`, { method });
    assert.equal(status, 405, method);
    assert.equal(res.headers.get('allow'), 'GET', method);
    assert.equal(res.headers.get('cache-control'), 'no-store', method);
    assertOnlyAllowedHeaders(assert, res);
  }
  assert.deepEqual(h.storage.calls, []);
  assert.deepEqual(h.cache.ops, []);
});

// ═══ 3. a post photo ══════════════════════════════════════════════════════════

test('a post photo: MISS fetches anonymously once, then HIT serves the edge copy', async () => {
  const h = harness();
  put(h, PHOTO, BYTES.jpg, { etag: '"photo-1"', lastModified: 'Sun, 01 Nov 2026 08:00:00 GMT' });

  const clientHeaders = {
    authorization: 'Bearer eyJ.firebase.token',
    cookie: 'session=secret',
    apikey: 'sb_publishable_client',
    range: 'bytes=0-3',
    'if-none-match': '"photo-1"',
    'if-modified-since': 'Sun, 01 Nov 2026 08:00:00 GMT',
    'x-forwarded-for': '102.0.0.1',
    'user-agent': 'Help24/1.0.12',
  };
  const first = await h.send(`/${PHOTO}`, { headers: clientHeaders });
  assert.equal(first.status, 200, 'a Range or a validator from the phone does not change the answer');
  assert.equal(first.headers.get('cf-cache-status'), 'MISS');
  assert.equal(first.headers.get('content-type'), 'image/jpeg');
  assert.equal(first.headers.get('content-length'), String(BYTES.jpg.length));
  assert.equal(first.headers.get('etag'), '"photo-1"');
  assert.equal(first.headers.get('last-modified'), 'Sun, 01 Nov 2026 08:00:00 GMT');
  assert.equal(first.headers.get('cache-control'), IMMUTABLE_CC);
  assertOnlyAllowedHeaders(assert, first.res);
  assert.deepEqual(first.body, BYTES.jpg);

  assert.equal(h.storage.calls.length, 1);
  const call = h.storage.calls[0];
  assert.equal(call.url, upstreamOf(PHOTO));
  assert.equal(call.method, 'GET');
  assert.equal(call.redirect, 'manual');
  assert.deepEqual([...call.headers.keys()], [], 'a client header was forwarded upstream');

  // The edge copy: keyed on the validated URL, with no client header in the key.
  assert.deepEqual([...h.cache.entries.keys()], [`${ORIGIN}/${PHOTO}`]);
  assert.ok(h.cache.ops.every((op) => op.headers.length === 0), 'a cache key carried headers');
  assert.equal(h.cache.entry(`${ORIGIN}/${PHOTO}`).headers.get('cache-control'), IMMUTABLE_CC);

  const second = await h.send(`/${PHOTO}`, { headers: clientHeaders });
  assert.equal(second.status, 200);
  assert.equal(second.headers.get('cf-cache-status'), 'HIT');
  assert.equal(second.headers.get('content-type'), 'image/jpeg');
  assert.equal(second.headers.get('etag'), '"photo-1"');
  assert.equal(second.headers.get('cache-control'), IMMUTABLE_CC);
  assertOnlyAllowedHeaders(assert, second.res);
  assert.deepEqual(second.body, BYTES.jpg);
  assert.equal(h.storage.calls.length, 1, 'a HIT went upstream');
});

test('each image type passes through, image/jpg is normalised, upper-case extensions load', async () => {
  const h = harness();
  const cases = [
    [`post-images/posts/${ID}.png`, BYTES.png, 'image/png', 'image/png'],
    [`post-images/posts/${ID}.gif`, BYTES.gif, 'image/gif', 'image/gif'],
    [`post-images/posts/${ID}.webp`, BYTES.webp, 'image/webp', 'image/webp'],
    [`post-images/posts/${ID}.jpeg`, BYTES.jpg, 'image/jpg', 'image/jpeg'],
    [`post-images/posts/${ID2}.PNG`, BYTES.png, 'IMAGE/PNG; charset=binary', 'image/png'],
  ];
  for (const [full, bytes, stored, served] of cases) {
    put(h, full, bytes, { type: stored });
    const { status, headers, body } = await h.send(`/${full}`);
    assert.equal(status, 200, full);
    assert.equal(headers.get('content-type'), served, full);
    assert.deepEqual(body, bytes, full);
  }
});

// ═══ 4. thumbnails ════════════════════════════════════════════════════════════

test('a thumbnail is the immutable class', async () => {
  const h = harness();
  put(h, THUMB, BYTES.jpg);
  const first = await h.send(`/${THUMB}`);
  assert.equal(first.status, 200);
  assert.equal(first.headers.get('cf-cache-status'), 'MISS');
  assert.equal(first.headers.get('cache-control'), IMMUTABLE_CC);
  // A year later it is still served from the edge, never revalidated.
  h.advance(300 * 24 * 60 * MINUTE);
  const second = await h.send(`/${THUMB}`);
  assert.equal(second.headers.get('cf-cache-status'), 'HIT');
  assert.equal(second.headers.get('cache-control'), IMMUTABLE_CC);
  assert.deepEqual(second.body, BYTES.jpg);
  assert.equal(h.storage.calls.length, 1);
});

test('a missing immutable name is a 404 the edge remembers for ten minutes', async () => {
  const h = harness();
  // Supabase answers a missing public object with 400 (FakeStorage's default) or 404.
  const first = await h.send(`/${THUMB}`);
  assert.equal(first.status, 404);
  assert.equal(first.headers.get('cache-control'), 'public, max-age=600');
  assert.equal(first.headers.get('cf-cache-status'), 'MISS');
  assertOnlyAllowedHeaders(assert, first.res);
  const stored = h.cache.entry(`${ORIGIN}/${THUMB}`);
  assert.equal(stored.status, 404);
  assert.equal(stored.headers.get('cache-control'), 'public, max-age=600');

  const second = await h.send(`/${THUMB}`);
  assert.equal(second.status, 404);
  assert.equal(second.headers.get('cf-cache-status'), 'HIT');
  assert.equal(h.storage.calls.length, 1, 'a remembered 404 went upstream');

  h.storage.failNext(404);
  const other = await h.send(`/${PHOTO}`);
  assert.equal(other.status, 404);
  assert.equal(h.cache.entry(`${ORIGIN}/${PHOTO}`).status, 404);
});

// ═══ 5. the query ═════════════════════════════════════════════════════════════

test('query: t is kept in the key and upstream; junk is dropped from both', async () => {
  const h = harness();
  put(h, AVATAR, BYTES.jpg);

  await h.send(`/${AVATAR}?t=123`);
  assert.equal(h.storage.calls.at(-1).url, upstreamOf(AVATAR, '?t=123'));
  assert.ok(h.cache.entries.has(`${ORIGIN}/${AVATAR}?t=123`));

  await h.send(`/${AVATAR}?x=1&t=abc`);
  assert.equal(h.storage.calls.at(-1).url, upstreamOf(AVATAR));
  assert.ok(h.cache.entries.has(`${ORIGIN}/${AVATAR}`));

  await h.send(`/${AVATAR}?t=1&x=2`);
  assert.equal(h.storage.calls.at(-1).url, upstreamOf(AVATAR, '?t=1'));
  assert.ok(h.cache.entries.has(`${ORIGIN}/${AVATAR}?t=1`));

  await h.send(`/${AVATAR}?t=${'1'.repeat(21)}`);
  assert.equal(h.storage.calls.length, 3, 'an over-long t made a new entry instead of sharing the bare one');

  assert.deepEqual([...h.cache.entries.keys()].sort(), [`${ORIGIN}/${AVATAR}`, `${ORIGIN}/${AVATAR}?t=1`, `${ORIGIN}/${AVATAR}?t=123`].sort());
});

test('query: two different junk queries share one cache entry', async () => {
  const h = harness();
  put(h, PHOTO, BYTES.jpg);
  const a = await h.send(`/${PHOTO}?utm_source=share&width=200`);
  const b = await h.send(`/${PHOTO}?cb=${Math.random()}&x=%2F..%2F`);
  assert.equal(a.headers.get('cf-cache-status'), 'MISS');
  assert.equal(b.headers.get('cf-cache-status'), 'HIT');
  assert.equal(h.storage.calls.length, 1);
  assert.equal(h.storage.calls[0].url, upstreamOf(PHOTO));
  assert.deepEqual([...h.cache.entries.keys()], [`${ORIGIN}/${PHOTO}`]);
});

test('query: an immutable photo ignores t, so it cannot fan out; an avatar keeps it, so it can bust', async () => {
  const h = harness();
  put(h, PHOTO, BYTES.jpg);
  put(h, AVATAR, BYTES.jpg);
  await h.send(`/${PHOTO}?t=1`);
  const again = await h.send(`/${PHOTO}?t=2`);
  assert.equal(again.headers.get('cf-cache-status'), 'HIT');
  assert.equal(h.storage.calls.length, 1);
  assert.equal(h.storage.calls[0].url, upstreamOf(PHOTO));

  await h.send(`/${AVATAR}?t=1`);
  const busted = await h.send(`/${AVATAR}?t=2`);
  assert.equal(busted.headers.get('cf-cache-status'), 'MISS');
  assert.equal(h.storage.calls.length, 3);
});

// ═══ 6. avatars: short cache with revalidation ════════════════════════════════

test('avatar lifecycle: MISS, HIT, REVALIDATED, EXPIRED, STALE, then removed', async () => {
  const h = harness();
  const path = `/${AVATAR}?t=1731745200000`;
  const key = `${ORIGIN}/${AVATAR}?t=1731745200000`;
  put(h, AVATAR, BYTES.jpg, { etag: '"e1"' });

  // MISS: one upstream call, stored for a day with an internal stamp.
  const miss = await h.send(path);
  assert.equal(miss.status, 200);
  assert.equal(miss.headers.get('cf-cache-status'), 'MISS');
  assert.equal(miss.headers.get('cache-control'), MUTABLE_CC);
  assert.equal(miss.headers.get('x-help24-stored-at'), null, 'the internal stamp reached a client');
  assertOnlyAllowedHeaders(assert, miss.res);
  assert.deepEqual(miss.body, BYTES.jpg);
  assert.equal(h.storage.calls.length, 1);
  let stored = h.cache.entry(key);
  assert.equal(stored.headers.get('cache-control'), 'public, max-age=86400');
  assert.equal(stored.headers.get('x-help24-stored-at'), String(h.clock.ms));

  // HIT inside five minutes: no upstream call.
  h.advance(4 * MINUTE);
  const hit = await h.send(path);
  assert.equal(hit.headers.get('cf-cache-status'), 'HIT');
  assert.equal(hit.headers.get('cache-control'), MUTABLE_CC);
  assert.equal(hit.headers.get('x-help24-stored-at'), null);
  assert.deepEqual(hit.body, BYTES.jpg);
  assert.equal(h.storage.calls.length, 1);

  // Past five minutes: a conditional request; 304 serves the stored bytes.
  h.advance(2 * MINUTE);
  const revalidated = await h.send(path, { headers: { 'if-none-match': '"client-etag"', authorization: 'Bearer x' } });
  assert.equal(revalidated.status, 200);
  assert.equal(revalidated.headers.get('cf-cache-status'), 'REVALIDATED');
  assert.equal(revalidated.headers.get('cache-control'), MUTABLE_CC);
  assert.equal(revalidated.headers.get('etag'), '"e1"');
  assertOnlyAllowedHeaders(assert, revalidated.res);
  assert.deepEqual(revalidated.body, BYTES.jpg);
  assert.equal(h.storage.calls.length, 2);
  const conditional = h.storage.calls[1];
  assert.equal(conditional.url, upstreamOf(AVATAR, '?t=1731745200000'));
  assert.equal(conditional.headers.get('if-none-match'), '"e1"', 'the STORED etag, not the client one');
  assert.ok(conditional.headers.get('if-modified-since'));
  assert.deepEqual([...conditional.headers.keys()].sort(), ['if-modified-since', 'if-none-match']);
  // Re-stored with a fresh stamp: the next four minutes are HITs again.
  stored = h.cache.entry(key);
  assert.equal(stored.headers.get('x-help24-stored-at'), String(h.clock.ms));
  h.advance(4 * MINUTE);
  assert.equal((await h.send(path)).headers.get('cf-cache-status'), 'HIT');
  assert.equal(h.storage.calls.length, 2);

  // The avatar is overwritten in place; once stale, the new bytes replace it.
  put(h, AVATAR, BYTES.jpg2, { etag: '"e2"' });
  h.advance(2 * MINUTE);
  const expired = await h.send(path);
  assert.equal(expired.headers.get('cf-cache-status'), 'EXPIRED');
  assert.equal(expired.headers.get('etag'), '"e2"');
  assert.equal(expired.headers.get('cache-control'), MUTABLE_CC);
  assert.deepEqual(expired.body, BYTES.jpg2);
  assert.equal(h.storage.calls.length, 3);
  assert.equal(h.storage.calls[2].headers.get('if-none-match'), '"e1"');
  assert.equal(h.cache.entry(key).headers.get('etag'), '"e2"');
  assert.deepEqual([...h.cache.entry(key).body], BYTES.jpg2);

  // Supabase failing: the stale copy stands in, and is not re-stamped.
  h.advance(6 * MINUTE);
  const stampBefore = h.cache.entry(key).headers.get('x-help24-stored-at');
  h.storage.failNext(500);
  const stale = await h.send(path);
  assert.equal(stale.status, 200);
  assert.equal(stale.headers.get('cf-cache-status'), 'STALE');
  assert.equal(stale.headers.get('cache-control'), MUTABLE_CC);
  assertOnlyAllowedHeaders(assert, stale.res);
  assert.deepEqual(stale.body, BYTES.jpg2);
  assert.equal(h.cache.entry(key).headers.get('x-help24-stored-at'), stampBefore);
  h.storage.failNext('network');
  const staleAgain = await h.send(path);
  assert.equal(staleAgain.headers.get('cf-cache-status'), 'STALE', 'the next request asked upstream again');
  assert.equal(h.storage.calls.length, 5);

  // The avatar is removed: 404, and the edge copy goes with it.
  h.storage.remove(...split(AVATAR));
  const gone = await h.send(path);
  assert.equal(gone.status, 404);
  assert.equal(gone.headers.get('cache-control'), 'no-store');
  assert.equal(h.cache.entry(key), undefined, 'the removed avatar is still cached');
  // A mutable 404 is never cached: the next request asks again.
  const goneAgain = await h.send(path);
  assert.equal(goneAgain.status, 404);
  assert.equal(h.storage.calls.length, 7);
  assert.equal(h.cache.entry(key), undefined);

  assertLogsAnonymous(h.events);
});

test('avatar without an etag revalidates by date', async () => {
  const h = harness();
  put(h, OLD_AVATAR, BYTES.png, { type: 'image/png', etag: null, lastModified: 'Sat, 01 Aug 2026 10:00:00 GMT' });
  assert.equal((await h.send(`/${OLD_AVATAR}`)).headers.get('cf-cache-status'), 'MISS');
  h.advance(10 * MINUTE);
  const res = await h.send(`/${OLD_AVATAR}`);
  assert.equal(res.headers.get('cf-cache-status'), 'REVALIDATED');
  assert.deepEqual(res.body, BYTES.png);
  const call = h.storage.calls[1];
  assert.deepEqual([...call.headers.keys()], ['if-modified-since']);
  assert.equal(call.headers.get('if-modified-since'), 'Sat, 01 Aug 2026 10:00:00 GMT');
});

test('avatar: an upstream failure with no stored copy is 502; a hang times out to STALE', async () => {
  const h = harness({ upstreamTimeoutMs: 20 });
  h.storage.failNext(503);
  const failed = await h.send(`/${AVATAR}`);
  assert.equal(failed.status, 502);
  assert.equal(failed.headers.get('cache-control'), 'no-store');
  assert.equal(h.cache.entries.size, 0);

  put(h, AVATAR, BYTES.jpg);
  assert.equal((await h.send(`/${AVATAR}`)).headers.get('cf-cache-status'), 'MISS');
  h.advance(6 * MINUTE);
  h.storage.failNext('hang');
  const stale = await h.send(`/${AVATAR}`);
  assert.equal(stale.headers.get('cf-cache-status'), 'STALE');
  assert.deepEqual(stale.body, BYTES.jpg);
  assert.ok(h.events.some((e) => e.event === 'upstream_failed' && e.reason === 'timeout'));
});

test('avatar: once Supabase refuses it (403), no stale copy is served and the entry is dropped', async () => {
  const h = harness();
  put(h, AVATAR, BYTES.jpg);
  await h.send(`/${AVATAR}`);
  h.advance(6 * MINUTE);
  h.storage.failNext(403);
  const res = await h.send(`/${AVATAR}`);
  assert.equal(res.status, 502);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(h.cache.entry(`${ORIGIN}/${AVATAR}`), undefined);
});

// ═══ 7. only images, typed by this Worker ═════════════════════════════════════

test('text/html and image/svg+xml upstream answers are refused and never cached', async () => {
  const h = harness();
  put(h, PHOTO, BYTES.html, { type: 'text/html; charset=utf-8' });
  put(h, THUMB, BYTES.svg, { type: 'image/svg+xml' });
  put(h, AVATAR, BYTES.html, { type: 'text/html' });
  for (const full of [PHOTO, THUMB, AVATAR]) {
    for (let i = 0; i < 2; i++) {
      const { status, res } = await h.send(`/${full}`);
      assert.equal(status, 404, full);
      assert.equal(res.headers.get('cache-control'), 'no-store', full);
      assert.equal(res.headers.get('content-type'), 'application/json; charset=utf-8', full);
    }
  }
  assert.equal(h.cache.entries.size, 0, 'a refused type was cached');
  assert.equal(h.storage.calls.length, 6, 'each refusal asked upstream again');
  assertLogsAnonymous(h.events);
});

test('octet-stream or no type: JPEG bytes are served as image/jpeg, HTML bytes are refused', async () => {
  const h = harness();
  put(h, PHOTO, BYTES.jpg, { type: 'application/octet-stream' });
  const first = await h.send(`/${PHOTO}`);
  assert.equal(first.status, 200);
  assert.equal(first.headers.get('content-type'), 'image/jpeg');
  assert.equal(first.headers.get('content-length'), String(BYTES.jpg.length));
  assert.deepEqual(first.body, BYTES.jpg);
  const second = await h.send(`/${PHOTO}`);
  assert.equal(second.headers.get('cf-cache-status'), 'HIT');
  assert.equal(second.headers.get('content-type'), 'image/jpeg');
  assert.deepEqual(second.body, BYTES.jpg);

  put(h, THUMB, BYTES.png, { type: null });
  assert.equal((await h.send(`/${THUMB}`)).headers.get('content-type'), 'image/png');

  const html = `post-images/posts/${ID2}.jpg`;
  put(h, html, BYTES.html, { type: 'application/octet-stream' });
  const refused = await h.send(`/${html}`);
  assert.equal(refused.status, 404);
  assert.equal(refused.headers.get('cache-control'), 'no-store');
  assert.equal(h.cache.entry(`${ORIGIN}/${html}`), undefined);

  const untyped = `post-images/posts/${ID2}.png`;
  put(h, untyped, BYTES.svg, { type: null });
  assert.equal((await h.send(`/${untyped}`)).status, 404);
});

test('a stored copy that is not an image this Worker would serve is ignored', async () => {
  const h = harness();
  put(h, PHOTO, BYTES.jpg);
  // Cache keys are per zone; pretend something else wrote under this one.
  h.cache.entries.set(`${ORIGIN}/${PHOTO}`, { status: 200, headers: [['content-type', 'text/html']], body: Uint8Array.from(BYTES.html) });
  const res = await h.send(`/${PHOTO}`);
  assert.equal(res.headers.get('cf-cache-status'), 'MISS');
  assert.equal(res.headers.get('content-type'), 'image/jpeg');
  assert.deepEqual(res.body, BYTES.jpg);
});

// ═══ 8. upstream failures on the immutable class ══════════════════════════════

test('immutable: 5xx, network errors, timeouts, redirects and 401/403 are 502 and never cached', async () => {
  const h = harness({ upstreamTimeoutMs: 20 });
  put(h, PHOTO, BYTES.jpg);
  for (const failure of [500, 502, 503, 'network', 'hang', 429, 401, 403, 302]) {
    h.storage.failNext(failure);
    const { status, res } = await h.send(`/${PHOTO}`);
    assert.equal(status, 502, String(failure));
    assert.equal(res.headers.get('cache-control'), 'no-store', String(failure));
    assert.equal(res.headers.get('cf-cache-status'), null, String(failure));
    assertOnlyAllowedHeaders(assert, res);
    assert.equal(h.cache.entries.size, 0, `${failure} was cached`);
  }
  // Nothing was remembered: the next request is a normal MISS.
  const ok = await h.send(`/${PHOTO}`);
  assert.equal(ok.status, 200);
  assert.equal(ok.headers.get('cf-cache-status'), 'MISS');
  assert.equal(h.storage.calls.length, 10);
  assert.ok(h.storage.calls.every((c) => c.redirect === 'manual'), 'a redirect could have been followed');

  const failures = h.events.filter((e) => e.event === 'upstream_failed');
  assert.equal(failures.length, 9);
  assert.deepEqual(failures[0], { event: 'upstream_failed', status: 500, bucket: 'post-images' });
  assert.deepEqual(failures[3], { event: 'upstream_failed', status: 0, bucket: 'post-images', reason: 'network' });
  assertLogsAnonymous(h.events);
});

test('a broken cache never breaks a photo', async () => {
  const storage = new FakeStorage();
  storage.put('post-images', `posts/${ID}.jpg`, BYTES.jpg);
  const events = [];
  const cache = {
    match: async () => {
      throw new Error('cache down');
    },
    put: () => {
      throw new TypeError('synchronous put failure');
    },
    delete: async () => false,
  };
  const app = createApp({ supabaseUrl: SUPABASE_URL, cache, fetch: storage.fetch, log: (e) => events.push(e) });
  const ctx = fakeCtx();
  const res = await app.fetch(new Request(`${ORIGIN}/${PHOTO}`), ctx);
  assert.equal(res.status, 200);
  assert.deepEqual([...new Uint8Array(await res.arrayBuffer())], BYTES.jpg);
  await ctx.settle();
  assert.deepEqual(
    events.filter((e) => e.event !== 'served').map((e) => `${e.event}:${e.op}`),
    ['cache_failed:match', 'cache_failed:put'],
  );
});

test('each photo request writes one served line: status, cache, kind, location, and no path', async () => {
  const h = harness();
  h.storage.put('post-images', `posts/${ID}.jpg`, BYTES.jpg);
  for (let i = 0; i < 2; i++) {
    const ctx = fakeCtx();
    const req = Object.assign(new Request(`${ORIGIN}/${PHOTO}`), { cf: { colo: 'NBO' } });
    await (await h.app.fetch(req, ctx)).arrayBuffer();
    await ctx.settle();
  }
  const served = h.events.filter((e) => e.event === 'served');
  assert.deepEqual(served, [
    { event: 'served', status: 200, cache: 'MISS', kind: 'immutable', colo: 'NBO' },
    { event: 'served', status: 200, cache: 'HIT', kind: 'immutable', colo: 'NBO' },
  ]);
});

// ═══ 9. configuration fails closed ════════════════════════════════════════════

test('createApp refuses a missing or malformed SUPABASE_URL, a missing cache or fetch', () => {
  const cache = new FakeCache();
  const fetch = new FakeStorage().fetch;
  for (const supabaseUrl of [undefined, '', 'http://projref.supabase.co', 'https://projref.supabase.co/storage/v1', 'not a url']) {
    assert.throws(() => createApp({ supabaseUrl, cache, fetch }), Error, String(supabaseUrl));
  }
  assert.throws(() => createApp({ supabaseUrl: SUPABASE_URL, cache: undefined, fetch }));
  assert.throws(() => createApp({ supabaseUrl: SUPABASE_URL, cache, fetch: undefined }));
  assert.ok(createApp({ supabaseUrl: `${SUPABASE_URL}/`, cache, fetch }));
});
