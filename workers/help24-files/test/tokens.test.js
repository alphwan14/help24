import { test } from 'node:test';
import assert from 'node:assert/strict';
import { b64urlDecode, b64urlEncode, memberTag, randomNonce, readCookies, signToken, tokenAcceptable, verifyToken } from '../src/tokens.js';

const SECRET = 'a-long-test-secret-for-tokens-0123456789';
const MSG = '1a1a1a1a-0000-4000-8000-000000000001';

test('a signed token verifies, and any change to it does not', async () => {
  const token = await signToken(SECRET, { v: 1, k: 'c', m: MSG, u: 'tag-0123456789abcdef', e: 9e9 });
  assert.deepEqual(await verifyToken(SECRET, token), { v: 1, k: 'c', m: MSG, u: 'tag-0123456789abcdef', e: 9e9 });
  assert.equal(await verifyToken('another-secret-0123456789-0123456789', token), null);
  const [body, sig] = token.split('.');
  const forged = b64urlEncode(new TextEncoder().encode(JSON.stringify({ v: 1, k: 'c', m: MSG, u: 'someone-else-0000', e: 9e9 })));
  assert.equal(await verifyToken(SECRET, `${forged}.${sig}`), null);
  assert.equal(await verifyToken(SECRET, `${body}.${sig.slice(0, -2)}AA`), null);
  for (const bad of ['', '.', `${body}.`, `.${sig}`, `${body}.${sig}.x`, `${body}.${sig}=`, 'x'.repeat(600), null, 42]) {
    assert.equal(await verifyToken(SECRET, bad), null, String(bad).slice(0, 20));
  }
});

test('member tags are keyed and stable, and do not reveal the uid', async () => {
  const a = await memberTag(SECRET, 'uid_alice');
  assert.equal(a, await memberTag(SECRET, 'uid_alice'));
  assert.notEqual(a, await memberTag(SECRET, 'uid_bob'));
  assert.notEqual(a, await memberTag('another-secret-0123456789-0123456789', 'uid_alice'));
  assert.equal(a.length, 27);
  assert.ok(!a.includes('alice'));
});

test('a member tag can never be passed off as a token signature (domain separation)', async () => {
  const token = await signToken(SECRET, { v: 1 });
  const tag = await memberTag(SECRET, 'x');
  assert.notEqual(token.split('.')[1].slice(0, 27), tag);
});

test('tokenAcceptable checks kind, document, expiry, shape', () => {
  const now = 1_000_000;
  const link = { v: 1, k: 'l', m: MSG, u: 'x'.repeat(27), e: now + 60, n: 'n'.repeat(22) };
  assert.ok(tokenAcceptable(link, { kind: 'l', messageId: MSG, nowSeconds: now }));
  assert.ok(tokenAcceptable(link, { kind: 'l', messageId: MSG.toUpperCase(), nowSeconds: now }));
  assert.ok(!tokenAcceptable(link, { kind: 'c', messageId: MSG, nowSeconds: now }), 'kind');
  assert.ok(!tokenAcceptable(link, { kind: 'l', messageId: MSG.replace('1a', '2a'), nowSeconds: now }), 'document');
  assert.ok(!tokenAcceptable(link, { kind: 'l', messageId: MSG, nowSeconds: now + 60 }), 'expiry');
  assert.ok(!tokenAcceptable({ ...link, n: undefined }, { kind: 'l', messageId: MSG, nowSeconds: now }), 'nonce');
  assert.ok(!tokenAcceptable({ ...link, v: 2 }, { kind: 'l', messageId: MSG, nowSeconds: now }), 'version');
  assert.ok(!tokenAcceptable({ ...link, u: 'short' }, { kind: 'l', messageId: MSG, nowSeconds: now }), 'tag');
  assert.ok(!tokenAcceptable({ ...link, e: String(now + 60) }, { kind: 'l', messageId: MSG, nowSeconds: now }), 'expiry type');
  assert.ok(!tokenAcceptable(null, { kind: 'l', messageId: MSG, nowSeconds: now }));
});

test('readCookies returns every value of our cookie and nothing else', () => {
  assert.deepEqual(readCookies('a=1; h24doc=x.y; h24docs=no; h24doc=z.w'), ['x.y', 'z.w']);
  assert.deepEqual(readCookies(''), []);
  assert.deepEqual(readCookies(null), []);
  assert.deepEqual(readCookies('h24doc'), []);
});

test('nonces are random and URL-safe', () => {
  const seen = new Set(Array.from({ length: 200 }, randomNonce));
  assert.equal(seen.size, 200);
  for (const n of seen) assert.match(n, /^[A-Za-z0-9_-]{22}$/);
  assert.deepEqual([...b64urlDecode(b64urlEncode(Uint8Array.from([0, 255, 62, 63])))], [0, 255, 62, 63]);
});
