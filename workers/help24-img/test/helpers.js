// Test doubles for the Worker. Nothing here talks to a network.
//
// FakeStorage answers ONLY anonymous GETs of Supabase public objects; any other
// upstream call throws, which fails the test that caused it. Every call it
// receives is recorded, which is how "refused paths never reach Supabase" and
// "no client header is forwarded" are checked: not by trusting the router, but
// by counting what it actually sent.

import { createApp } from '../src/app.js';

export const SUPABASE_URL = 'https://projref.supabase.co';
export const ORIGIN = 'https://img.help24.co.ke';
const PUBLIC_PREFIX = '/storage/v1/object/public/';

// Minimal file headers for the magic-byte checks.
export const BYTES = {
  jpg: [0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 2, 3, 4],
  jpg2: [0xff, 0xd8, 0xff, 0xe1, 9, 9, 9, 9, 9, 9, 9, 9],
  png: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 1, 2, 3],
  gif: [0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0, 0],
  webp: [0x52, 0x49, 0x46, 0x46, 0x24, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20],
  html: [...new TextEncoder().encode('<!doctype html><script>alert(1)</script>')],
  svg: [...new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>')],
};

export class FakeStorage {
  constructor() {
    this.objects = new Map();
    this.calls = [];
    /** Queue of failures for the next calls: a status, 'network' or 'hang'. */
    this.failures = [];
    this.version = 0;
    this.fetch = this.fetch.bind(this);
  }

  /** Store an object. `type: null` stores it without a content type;
   *  `etag: null` without an etag (revalidation then uses the date). */
  put(bucket, path, bytes, { type = 'image/jpeg', etag, lastModified } = {}) {
    this.version += 1;
    this.objects.set(`${bucket}/${path}`, {
      bytes: Uint8Array.from(bytes),
      type,
      etag: etag === undefined ? `"v${this.version}"` : etag,
      lastModified: lastModified ?? new Date(Date.UTC(2026, 10, 1, 0, 0, this.version)).toUTCString(),
    });
  }

  remove(bucket, path) {
    this.objects.delete(`${bucket}/${path}`);
  }

  failNext(...failures) {
    this.failures.push(...failures);
  }

  async fetch(input, init = {}) {
    const url = new URL(typeof input === 'string' ? input : input.url);
    const method = (init.method ?? 'GET').toUpperCase();
    const headers = new Headers(init.headers);
    this.calls.push({ url: url.href, method, headers, redirect: init.redirect });

    if (url.origin !== SUPABASE_URL) throw new Error(`upstream call to a foreign origin: ${url.origin}`);
    if (method !== 'GET' || !url.pathname.startsWith(PUBLIC_PREFIX)) {
      throw new Error(`unexpected upstream call ${method} ${url.pathname}`);
    }

    const failure = this.failures.shift();
    if (failure === 'network') throw new TypeError('fetch failed');
    if (failure === 'hang') {
      return new Promise((_, reject) => {
        init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
      });
    }
    if (typeof failure === 'number') {
      return new Response(`{"message":"internal detail from ${SUPABASE_URL}"}`, { status: failure, headers: hostile() });
    }

    const object = this.objects.get(url.pathname.slice(PUBLIC_PREFIX.length));
    if (!object) {
      return new Response('{"statusCode":"404","error":"not_found","message":"Object not found"}', {
        status: 400,
        headers: { ...hostile(), 'content-type': 'application/json' },
      });
    }
    const validators = { 'last-modified': object.lastModified };
    if (object.etag !== null) validators.etag = object.etag;
    const base = { ...hostile(), ...validators };
    if (object.type !== null) base['content-type'] = object.type;

    const inm = headers.get('if-none-match');
    const ims = headers.get('if-modified-since');
    if ((inm !== null && inm === object.etag) || (inm === null && ims !== null && ims === object.lastModified)) {
      return new Response(null, { status: 304, headers: { ...hostile(), ...validators } });
    }
    return new Response(object.bytes, { status: 200, headers: { ...base, 'content-length': String(object.bytes.length) } });
  }
}

/** Headers Supabase (or anything in front of it) might add. None may reach a caller. */
function hostile() {
  return {
    server: 'supabase-storage',
    'set-cookie': 'upstream=1; Path=/',
    'x-upstream-secret': 'must-not-leak',
    'x-sb-request-id': 'sb-123',
    'cf-cache-status': 'DYNAMIC',
    'cf-ray': 'abc123-DUB',
    'access-control-allow-origin': '*',
    vary: 'Origin',
  };
}

/**
 * The Cache API contract the Worker relies on: put stores a copy keyed by URL,
 * match returns a fresh Response each time, delete removes it. Expiry is not
 * modelled: the Worker tracks the MUTABLE copy's age itself, and an IMMUTABLE
 * copy never needs to expire within a test.
 */
export class FakeCache {
  constructor() {
    this.entries = new Map();
    this.ops = [];
  }

  #key(request, op) {
    const r = typeof request === 'string' ? new Request(request) : request;
    if (r.method !== 'GET') throw new TypeError(`cache ${op} with a ${r.method} key`);
    this.ops.push({ op, url: r.url, headers: [...r.headers.keys()] });
    return r.url;
  }

  async match(request) {
    const entry = this.entries.get(this.#key(request, 'match'));
    if (!entry) return undefined;
    return new Response(entry.body, { status: entry.status, headers: entry.headers });
  }

  async put(request, response) {
    const key = this.#key(request, 'put');
    if (response.status === 206) throw new TypeError('cannot cache a 206');
    const body = new Uint8Array(await response.arrayBuffer());
    this.entries.set(key, { status: response.status, headers: [...response.headers], body });
  }

  async delete(request) {
    return this.entries.delete(this.#key(request, 'delete'));
  }

  /** The stored entry for a URL, with its headers as a Headers object. */
  entry(url) {
    const e = this.entries.get(url);
    return e ? { ...e, headers: new Headers(e.headers) } : undefined;
  }
}

/** ctx.waitUntil, with a way for a test to wait for the cache writes. */
export function fakeCtx() {
  const pending = [];
  return {
    pending,
    waitUntil(promise) {
      pending.push(promise);
    },
    async settle() {
      while (pending.length > 0) await Promise.all(pending.splice(0));
    },
  };
}

/** The app wired with doubles, and a `get` that settles cache writes. */
export function harness({ now, upstreamTimeoutMs } = {}) {
  const clock = { ms: now ?? Date.UTC(2026, 10, 16, 9, 0, 0) };
  const storage = new FakeStorage();
  const cache = new FakeCache();
  const events = [];
  const app = createApp({
    supabaseUrl: SUPABASE_URL,
    cache,
    fetch: storage.fetch,
    now: () => clock.ms,
    log: (e) => events.push(e),
    upstreamTimeoutMs,
  });

  async function send(path, { method = 'GET', headers = {} } = {}) {
    const ctx = fakeCtx();
    const res = await app.fetch(new Request(`${ORIGIN}${path}`, { method, headers }), ctx);
    const body = [...new Uint8Array(await res.arrayBuffer())];
    await ctx.settle();
    return { res, status: res.status, headers: res.headers, body };
  }

  const advance = (ms) => {
    clock.ms += ms;
  };
  return { app, storage, cache, clock, events, send, advance };
}

/** Every header a served photo may carry. Anything else is a leak. */
export const ALLOWED_HEADERS = new Set([
  'content-type',
  'content-length',
  'etag',
  'last-modified',
  'cache-control',
  'x-content-type-options',
  'content-security-policy',
  'cf-cache-status',
  'allow',
]);

export function assertOnlyAllowedHeaders(assert, res) {
  for (const [name, value] of res.headers) {
    assert.ok(ALLOWED_HEADERS.has(name), `response carried "${name}: ${value}"`);
  }
  assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(res.headers.get('content-security-policy'), "default-src 'none'; sandbox");
}

export const MINUTE = 60 * 1000;
