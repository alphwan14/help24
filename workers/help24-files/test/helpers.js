// Test doubles for the Worker. Nothing here talks to a network.
//
// FakeSupabase answers ONLY the four request shapes the Worker is allowed to
// make; any other upstream call throws, which fails the test that caused it.
// That is how "the Worker cannot be used as a proxy" is checked: not by
// trusting the router, but by recording every upstream request it made.

import { createApp } from '../src/app.js';
import { createFirebaseVerifier } from '../src/firebase-auth.js';
import { createSupabase } from '../src/supabase.js';
import { b64urlEncode } from '../src/tokens.js';

export const PROJECT_ID = 'help24-test';
export const SUPABASE_URL = 'https://projref.supabase.co';
export const SERVICE_KEY = 'sb_secret_TEST_service_key_0123456789abcdef';
export const SIGNING_SECRET = 'test-signing-secret-0123456789-abcdefghijklmnop';
export const JWKS_URL = 'https://keys.test/jwks';

const encoder = new TextEncoder();

// ── Firebase-shaped tokens signed by a local RSA key ─────────────────────────

export async function makeSigner(kid = 'kid-1') {
  const pair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  );
  const jwk = { ...(await crypto.subtle.exportKey('jwk', pair.publicKey)), kid, alg: 'RS256', use: 'sig' };
  async function sign(claims, header = {}) {
    const h = b64urlEncode(encoder.encode(JSON.stringify({ alg: 'RS256', kid, typ: 'JWT', ...header })));
    const p = b64urlEncode(encoder.encode(JSON.stringify(claims)));
    const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', pair.privateKey, encoder.encode(`${h}.${p}`));
    return `${h}.${p}.${b64urlEncode(new Uint8Array(sig))}`;
  }
  return { kid, jwk, sign };
}

export function claimsFor(uid, nowMs = Date.now(), overrides = {}) {
  const now = Math.floor(nowMs / 1000);
  return {
    iss: `https://securetoken.google.com/${PROJECT_ID}`,
    aud: PROJECT_ID,
    sub: uid,
    user_id: uid,
    iat: now - 10,
    auth_time: now - 100,
    exp: now + 3600,
    ...overrides,
  };
}

/** A fetch that serves a JWKS document and counts how often it was asked. */
export function jwksFetch(getKeys, { maxAge = 3600 } = {}) {
  const fn = async (url) => {
    fn.calls++;
    if (String(url) !== JWKS_URL) throw new Error(`unexpected JWKS fetch ${url}`);
    if (fn.fail) return new Response('down', { status: 503 });
    return new Response(JSON.stringify({ keys: getKeys() }), {
      status: 200,
      headers: { 'content-type': 'application/json', 'cache-control': `public, max-age=${maxAge}` },
    });
  };
  fn.calls = 0;
  fn.fail = false;
  return fn;
}

// ── Supabase ──────────────────────────────────────────────────────────────────

const MESSAGE_SELECT = 'id,chat_id,sender_id,type,content,attachment_url,deleted_for_everyone,chats(user1,user2)';

export class FakeSupabase {
  constructor() {
    this.chats = new Map();
    this.messages = new Map();
    this.objects = new Map();
    this.calls = [];
    /** Set to a status to make the next upstream call fail with it. */
    this.failWith = null;
    this.fetch = this.fetch.bind(this);
  }

  addChat(id, user1, user2) {
    this.chats.set(id, { user1, user2 });
  }

  addMessage(row) {
    this.messages.set(row.id, { type: 'text', content: '', attachment_url: null, deleted_for_everyone: false, ...row });
  }

  putObject(bucket, key, bytes) {
    this.objects.set(`${bucket}/${key}`, { bytes: Uint8Array.from(bytes), etag: `"etag-${this.objects.size}"` });
  }

  objectCalls() {
    return this.calls.filter((c) => c.path.startsWith('/storage/'));
  }

  async fetch(input, init = {}) {
    const url = new URL(typeof input === 'string' ? input : input.url);
    const method = (init.method ?? 'GET').toUpperCase();
    const headers = new Headers(init.headers);
    this.calls.push({ method, path: url.pathname, search: url.search, headers });

    if (url.origin !== SUPABASE_URL) throw new Error(`upstream call to a foreign origin: ${url.origin}`);
    if (headers.get('apikey') !== SERVICE_KEY) return new Response('{"message":"Invalid API key"}', { status: 401 });
    if (this.failWith) {
      const status = this.failWith;
      this.failWith = null;
      return new Response(`{"message":"internal detail from ${SUPABASE_URL}"}`, { status });
    }

    if (method === 'GET' && url.pathname === '/rest/v1/chat_messages') {
      if (url.searchParams.get('select') !== MESSAGE_SELECT) throw new Error(`unexpected select ${url.search}`);
      const id = /^eq\.(.+)$/.exec(url.searchParams.get('id') ?? '')?.[1];
      const row = this.messages.get(id);
      if (!row) return jsonResponse([]);
      const chat = this.chats.get(row.chat_id) ?? null;
      return jsonResponse([{ ...row, chats: chat ? { ...chat } : null }]);
    }

    if (method === 'GET' && url.pathname === '/rest/v1/chats') {
      if (url.searchParams.get('select') !== 'user1,user2') throw new Error(`unexpected select ${url.search}`);
      const id = /^eq\.(.+)$/.exec(url.searchParams.get('id') ?? '')?.[1];
      const chat = this.chats.get(id);
      return jsonResponse(chat ? [{ ...chat }] : []);
    }

    const readPrefix = '/storage/v1/object/authenticated/';
    if (method === 'GET' && url.pathname.startsWith(readPrefix)) {
      const path = url.pathname.slice(readPrefix.length).split('/').map(decodeURIComponent).join('/');
      const object = this.objects.get(path);
      if (!object) {
        return new Response('{"statusCode":"404","error":"not_found","message":"Object not found"}', { status: 400 });
      }
      // Hostile upstream headers: none of these may reach a caller.
      const base = {
        'content-type': 'text/html',
        server: 'supabase-storage',
        'x-upstream-secret': 'must-not-leak',
        'set-cookie': 'upstream=1',
        'access-control-allow-origin': '*',
        etag: object.etag,
        'last-modified': 'Mon, 01 Jan 2024 00:00:00 GMT',
      };
      if (headers.get('if-none-match') === object.etag) return new Response(null, { status: 304, headers: base });
      const range = /^bytes=(\d*)-(\d*)$/.exec(headers.get('range') ?? '');
      if (range) {
        const size = object.bytes.length;
        const start = range[1] === '' ? size - Number(range[2]) : Number(range[1]);
        const end = range[1] === '' || range[2] === '' ? size - 1 : Math.min(Number(range[2]), size - 1);
        if (start >= size) return new Response(null, { status: 416, headers: { ...base, 'content-range': `bytes */${size}` } });
        const slice = object.bytes.slice(start, end + 1);
        return new Response(slice, {
          status: 206,
          headers: { ...base, 'content-range': `bytes ${start}-${end}/${size}`, 'content-length': String(slice.length) },
        });
      }
      return new Response(object.bytes, { status: 200, headers: { ...base, 'content-length': String(object.bytes.length) } });
    }

    const writePrefix = '/storage/v1/object/';
    if (method === 'POST' && url.pathname.startsWith(writePrefix) && !url.pathname.startsWith(readPrefix)) {
      if (headers.get('x-upsert') !== 'false') throw new Error('upload without x-upsert: false');
      const path = url.pathname.slice(writePrefix.length).split('/').map(decodeURIComponent).join('/');
      if (this.objects.has(path)) {
        return new Response('{"statusCode":"409","error":"Duplicate","message":"The resource already exists"}', { status: 400 });
      }
      const body = init.body instanceof Uint8Array ? init.body : new Uint8Array(await new Response(init.body).arrayBuffer());
      this.objects.set(path, { bytes: Uint8Array.from(body), etag: `"etag-${this.objects.size}"`, contentType: headers.get('content-type') });
      return jsonResponse({ Key: path });
    }

    throw new Error(`unexpected upstream call ${method} ${url.pathname}`);
  }
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

// ── one-time nonces and rate limits ──────────────────────────────────────────

/** The Durable Object's contract: true the first time, false ever after. */
export function memoryNonces() {
  const used = new Set();
  return {
    used,
    async burn(nonce) {
      if (used.has(nonce)) return false;
      used.add(nonce);
      return true;
    },
  };
}

/** A rate-limit binding allowing [limit] calls per key, ever (the test's "minute"). */
export function countingLimiter(limit) {
  const counts = new Map();
  return {
    counts,
    async limit({ key }) {
      const n = (counts.get(key) ?? 0) + 1;
      counts.set(key, n);
      return { success: n <= limit };
    },
  };
}

// ── the app, wired with doubles ───────────────────────────────────────────────

export async function harness({ now, limits } = {}) {
  const clock = { ms: now ?? Date.UTC(2026, 9, 4, 12, 0, 0) };
  const signer = await makeSigner();
  const jwks = jwksFetch(() => [signer.jwk]);
  const db = new FakeSupabase();
  const nonces = memoryNonces();
  const events = [];
  const app = createApp({
    verifyIdToken: createFirebaseVerifier({ projectId: PROJECT_ID, fetchImpl: jwks, now: () => clock.ms, jwksUrl: JWKS_URL }),
    supabase: createSupabase({ url: SUPABASE_URL, serviceKey: SERVICE_KEY, fetchImpl: db.fetch }),
    nonces,
    signingSecret: SIGNING_SECRET,
    limits,
    now: () => clock.ms,
    log: (e) => events.push(e),
  });
  const tokenFor = (uid, overrides) => signer.sign(claimsFor(uid, clock.ms, overrides));
  return { app, db, nonces, clock, signer, jwks, events, tokenFor };
}

export const ORIGIN = 'https://files.help24.co.ke';

export function req(path, { method = 'GET', token, headers = {}, body } = {}) {
  const h = new Headers(headers);
  if (token) h.set('authorization', `Bearer ${token}`);
  return new Request(`${ORIGIN}${path}`, { method, headers: h, body, duplex: body ? 'half' : undefined });
}

/** Everything a caller could read from a response, as one string. */
export async function exposed(response) {
  const head = [...response.headers.entries()].map(([k, v]) => `${k}: ${v}`).join('\n');
  const body = response.body ? await response.clone().text() : '';
  return `${response.status}\n${head}\n\n${body}`;
}

export function assertNoLeak(assert, text) {
  for (const needle of ['supabase', 'projref', SERVICE_KEY, 'sb_secret', 'must-not-leak', 'upstream=1', 'internal detail']) {
    assert.ok(!text.toLowerCase().includes(needle.toLowerCase()), `response leaked "${needle}":\n${text}`);
  }
}

// Minimal valid file headers for the magic-byte check.
export const BYTES = {
  jpg: [0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 2, 3, 4],
  png: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 1, 2, 3],
  pdf: [...encoder.encode('%PDF-1.7\n%âãÏÓ\n1 0 obj\n<<>>\nendobj\ntrailer\n%%EOF\n')],
  docx: [0x50, 0x4b, 0x03, 0x04, 0x14, 0, 6, 0, 8, 0, 0, 0],
  html: [...encoder.encode('<!doctype html><script>alert(1)</script>')],
};
