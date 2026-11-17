// The Worker entry: bindings in, fail closed when one is missing. It builds the
// app once per isolate, so the test that finally builds one runs last.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { BYTES, FakeCache, FakeStorage, ORIGIN, SUPABASE_URL, fakeCtx } from './helpers.js';

const PHOTO = 'post-images/posts/3f2b8c1e-9a4d-4e7b-8c21-5d6e7f8a9b0c.jpg';

/** Run [fn] with console output captured, and globals swapped for doubles. */
async function withGlobals(globals, fn) {
  const saved = {};
  for (const name of [...Object.keys(globals), 'console']) saved[name] = Object.getOwnPropertyDescriptor(globalThis, name);
  const lines = [];
  const quiet = { ...console, log: (line) => lines.push(line), error: (line) => lines.push(line) };
  try {
    Object.defineProperty(globalThis, 'console', { value: quiet, configurable: true, writable: true });
    for (const [name, value] of Object.entries(globals)) {
      Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
    }
    return await fn(lines);
  } finally {
    for (const [name, descriptor] of Object.entries(saved)) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else delete globalThis[name];
    }
  }
}

async function assertUnavailable(res) {
  assert.equal(res.status, 503);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
  assert.deepEqual(await res.json(), { code: 'UNAVAILABLE' });
}

test('missing SUPABASE_URL: every request is 503, no-store, and nothing goes upstream', async () => {
  const storage = new FakeStorage();
  await withGlobals({ caches: { default: new FakeCache() }, fetch: storage.fetch }, async (lines) => {
    for (const env of [{}, { SUPABASE_URL: '' }, undefined]) {
      await assertUnavailable(await worker.fetch(new Request(`${ORIGIN}/${PHOTO}`), env, fakeCtx()));
    }
    assert.ok(lines.some((l) => l.includes('config_missing') && l.includes('SUPABASE_URL')));
  });
  assert.deepEqual(storage.calls, []);
});

test('a malformed SUPABASE_URL or no edge cache also fails closed', async () => {
  const storage = new FakeStorage();
  await withGlobals({ caches: { default: new FakeCache() }, fetch: storage.fetch }, async (lines) => {
    await assertUnavailable(await worker.fetch(new Request(`${ORIGIN}/${PHOTO}`), { SUPABASE_URL: 'http://projref.supabase.co' }, fakeCtx()));
    assert.ok(lines.some((l) => l.includes('config_invalid')));
  });
  await withGlobals({ caches: undefined, fetch: storage.fetch }, async (lines) => {
    await assertUnavailable(await worker.fetch(new Request(`${ORIGIN}/${PHOTO}`), { SUPABASE_URL }, fakeCtx()));
    assert.ok(lines.some((l) => l.includes('caches.default')));
  });
  assert.deepEqual(storage.calls, []);
});

test('with its bindings the entry serves through caches.default and the global fetch', async () => {
  const storage = new FakeStorage();
  storage.put('post-images', PHOTO.slice('post-images/'.length), BYTES.jpg);
  const cache = new FakeCache();
  await withGlobals({ caches: { default: cache }, fetch: storage.fetch }, async () => {
    const ctx = fakeCtx();
    const res = await worker.fetch(new Request(`${ORIGIN}/${PHOTO}`), { SUPABASE_URL }, ctx);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cf-cache-status'), 'MISS');
    assert.deepEqual([...new Uint8Array(await res.arrayBuffer())], BYTES.jpg);
    await ctx.settle();
    assert.ok(ctx.pending.length === 0 && cache.entries.has(`${ORIGIN}/${PHOTO}`), 'the copy was not stored through ctx.waitUntil');
  });
  assert.equal(storage.calls.length, 1);
  assert.equal(storage.calls[0].url, `${SUPABASE_URL}/storage/v1/object/public/${PHOTO}`);
});
