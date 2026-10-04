import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createFirebaseVerifier } from '../src/firebase-auth.js';
import { JWKS_URL, PROJECT_ID, claimsFor, jwksFetch, makeSigner } from './helpers.js';

async function setup() {
  const clock = { ms: Date.UTC(2026, 9, 4, 12) };
  const a = await makeSigner('kid-a');
  let keys = [a.jwk];
  const fetchImpl = jwksFetch(() => keys);
  const verify = createFirebaseVerifier({ projectId: PROJECT_ID, fetchImpl, now: () => clock.ms, jwksUrl: JWKS_URL });
  return { clock, a, fetchImpl, verify, setKeys: (k) => (keys = k) };
}

test('a genuine token yields its uid; keys are fetched once and reused', async () => {
  const { a, clock, fetchImpl, verify } = await setup();
  for (let i = 0; i < 5; i++) {
    assert.deepEqual(await verify(await a.sign(claimsFor('uid_1', clock.ms))), { ok: true, uid: 'uid_1' });
  }
  assert.equal(fetchImpl.calls, 1);
});

test('expired tokens are "expired"; every other defect is "invalid" or "malformed"', async () => {
  const { a, clock, verify } = await setup();
  const now = Math.floor(clock.ms / 1000);
  assert.deepEqual(await verify(await a.sign(claimsFor('u', clock.ms, { exp: now }))), { ok: false, reason: 'expired' });
  assert.deepEqual(await verify(await a.sign(claimsFor('u', clock.ms, { aud: 'x' }))), { ok: false, reason: 'invalid' });
  assert.deepEqual(await verify(await a.sign(claimsFor('u', clock.ms, { iss: 'https://accounts.google.com' }))), { ok: false, reason: 'invalid' });
  assert.deepEqual(await verify(await a.sign(claimsFor('u', clock.ms, { auth_time: now + 3600 }))), { ok: false, reason: 'invalid' });
  assert.deepEqual(await verify(await a.sign(claimsFor('u', clock.ms, { auth_time: undefined }))), { ok: false, reason: 'invalid' });
  assert.deepEqual(await verify(await a.sign(claimsFor('x'.repeat(129), clock.ms))), { ok: false, reason: 'invalid' });
  assert.deepEqual(await verify(await a.sign(claimsFor('u', clock.ms), { kid: undefined })), { ok: false, reason: 'invalid' });
  assert.deepEqual(await verify('a.b'), { ok: false, reason: 'malformed' });
  assert.deepEqual(await verify(''), { ok: false, reason: 'malformed' });
  assert.deepEqual(await verify('!!!.!!!.!!!'), { ok: false, reason: 'malformed' });
});

test('a token signed with an unknown key forces one refetch, then is refused', async () => {
  const { clock, fetchImpl, verify, a } = await setup();
  await verify(await a.sign(claimsFor('u', clock.ms)));
  const stranger = await makeSigner('kid-unknown');
  for (let i = 0; i < 10; i++) {
    assert.deepEqual(await verify(await stranger.sign(claimsFor('u', clock.ms))), { ok: false, reason: 'invalid' });
  }
  assert.equal(fetchImpl.calls, 2, 'junk kids cannot turn every request into a key fetch');
});

test('rotated keys are picked up', async () => {
  const { clock, verify, a, setKeys } = await setup();
  await verify(await a.sign(claimsFor('u', clock.ms)));
  const b = await makeSigner('kid-b');
  setKeys([a.jwk, b.jwk]);
  clock.ms += 61_000;
  assert.deepEqual(await verify(await b.sign(claimsFor('u2', clock.ms))), { ok: true, uid: 'u2' });
});

test('Google unreachable with no keys yet is "unavailable"; with keys in hand it keeps working', async () => {
  const fresh = await setup();
  fresh.fetchImpl.fail = true;
  assert.deepEqual(await fresh.verify(await fresh.a.sign(claimsFor('u', fresh.clock.ms))), { ok: false, reason: 'unavailable' });

  const warm = await setup();
  await warm.verify(await warm.a.sign(claimsFor('u', warm.clock.ms)));
  warm.fetchImpl.fail = true;
  warm.clock.ms += 2 * 3600 * 1000; // past the key set's max-age
  assert.deepEqual(await warm.verify(await warm.a.sign(claimsFor('u', warm.clock.ms))), { ok: true, uid: 'u' });
});
