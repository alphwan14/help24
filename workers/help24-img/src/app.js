// img.help24.co.ke: the public photos the app shows (post photos, their
// thumbnails, avatars), fetched from Supabase Storage once and kept at the
// Cloudflare edge, so a phone in Kenya stops waiting on a round trip to Dublin.
//
//   GET /<bucket>/<object path>[?t=<digits>]
//
// THE RULES EVERY REQUEST KEEPS:
//   - Only paths policy.js allowlists are fetched; anything else is a 404 with
//     no upstream call and no cache lookup.
//   - Nothing from the client reaches Supabase: no headers (no cookie, no
//     Authorization, no Range), no query beyond a validated `t`. Public
//     buckets are read anonymously; this Worker holds no key.
//   - The cache key is built from the validated parts alone, so junk query
//     strings and client headers cannot fan one photo out into many entries.
//   - Only image/jpeg, png, gif and webp are ever served, with headers this
//     Worker chooses; no upstream header passes through except the validators
//     (etag, last-modified) and the length.

import {
  FRESH_MS,
  IMAGE_TYPES,
  IMMUTABLE,
  IMMUTABLE_CACHE_CONTROL,
  MISSING_CACHE_CONTROL,
  MUTABLE_CLIENT_CACHE_CONTROL,
  MUTABLE_STORED_CACHE_CONTROL,
  SECURITY_HEADERS,
  SNIFF,
  STORED_AT_HEADER,
  cacheKeyUrl,
  declaredImageType,
  resolveImage,
  sniffImageType,
  supabaseOrigin,
  upstreamUrl,
} from './policy.js';

/** An object stored without a type is read whole to prove what it is. Both
 *  buckets cap uploads at 5 MB; past this it cannot be a Help24 photo. */
const MAX_SNIFF_BYTES = 10 * 1024 * 1024;

/**
 * @param {object} deps
 * @param {string} deps.supabaseUrl          https://<ref>.supabase.co
 * @param {{match(r: Request): Promise<Response|undefined>, put(r: Request, res: Response): Promise<void>, delete(r: Request): Promise<boolean>}} deps.cache
 *        caches.default in production
 * @param {(input: string, init: RequestInit) => Promise<Response>} deps.fetch
 * @param {() => number} [deps.now]          milliseconds
 * @param {(event: object) => void} [deps.log] never receives a uid or a path
 * @param {number} [deps.upstreamTimeoutMs]  how long to wait for Supabase's response headers
 */
export function createApp({ supabaseUrl, cache, fetch: fetchImpl, now = () => Date.now(), log = () => {}, upstreamTimeoutMs = 10_000 }) {
  const origin = supabaseOrigin(supabaseUrl);
  if (!cache || typeof cache.match !== 'function' || typeof cache.put !== 'function' || typeof cache.delete !== 'function') {
    throw new Error('createApp: a cache with match/put/delete is required');
  }
  if (typeof fetchImpl !== 'function') throw new Error('createApp: fetch is required');

  // ── responses ─────────────────────────────────────────────────────────────

  function json(status, code, extra = {}) {
    return new Response(JSON.stringify({ code }), {
      status,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
        ...SECURITY_HEADERS,
        ...extra,
      },
    });
  }

  const notFound = () => json(404, 'NOT_FOUND');
  const badGateway = () => json(502, 'UPSTREAM_UNAVAILABLE');
  /** An IMMUTABLE name that does not exist: safe to remember for ten minutes. */
  const missing = (cacheStatus) =>
    json(404, 'NOT_FOUND', { 'cache-control': MISSING_CACHE_CONTROL, ...(cacheStatus ? { 'cf-cache-status': cacheStatus } : {}) });

  /** A photo, with exactly the headers this Worker allows. */
  function image(body, meta, cacheControl, cacheStatus, extra = {}) {
    const headers = new Headers({ 'content-type': meta.type, 'cache-control': cacheControl, ...SECURITY_HEADERS, ...extra });
    if (meta.length) headers.set('content-length', meta.length);
    if (meta.etag) headers.set('etag', meta.etag);
    if (meta.lastModified) headers.set('last-modified', meta.lastModified);
    if (cacheStatus) headers.set('cf-cache-status', cacheStatus);
    return new Response(body, { status: 200, headers });
  }

  // ── cache ─────────────────────────────────────────────────────────────────

  /** A cache failure is never an error for the caller: it is a miss. */
  async function lookup(key) {
    try {
      return (await cache.match(key)) ?? null;
    } catch (e) {
      log({ event: 'cache_failed', op: 'match', detail: e?.name });
      return null;
    }
  }

  /**
   * Cache writes run after the response is on its way (ctx.waitUntil), and
   * no failure of theirs, not even a synchronous throw, reaches the caller.
   */
  function later(ctx, op, run) {
    let promise;
    try {
      promise = Promise.resolve(run());
    } catch (e) {
      promise = Promise.reject(e);
    }
    const settled = promise.catch((e) => log({ event: 'cache_failed', op, detail: e?.name }));
    if (ctx && typeof ctx.waitUntil === 'function') ctx.waitUntil(settled);
  }

  /** Store the copy of [response] the edge keeps. [response] stays readable. */
  function store(ctx, key, response, meta, kind) {
    const extra = kind === IMMUTABLE ? {} : { [STORED_AT_HEADER]: String(now()) };
    const cacheControl = kind === IMMUTABLE ? IMMUTABLE_CACHE_CONTROL : MUTABLE_STORED_CACHE_CONTROL;
    const copy = image(response.clone().body, meta, cacheControl, null, extra);
    later(ctx, 'put', () => cache.put(key, copy));
  }

  /** What a stored photo says about itself, or null if it is not one of ours. */
  function storedMeta(stored) {
    if (stored.status !== 200) return null;
    const type = stored.headers.get('content-type');
    // Cache keys are per zone: refuse anything this Worker would not have stored.
    if (!IMAGE_TYPES.includes(type)) return null;
    return metaFrom(stored.headers, type);
  }

  // ── upstream ──────────────────────────────────────────────────────────────

  /**
   * One anonymous GET to Supabase. The only headers it ever carries are the
   * validators of a stored copy. Never throws; answers one of:
   *   image        200 and an allowed image ({ body, meta })
   *   not_modified 304 ({ meta }: the validators it carried)
   *   missing      400 / 404: no such object
   *   not_image    200 that is not an allowed image
   *   transient    5xx, 429, network error, timeout
   *   refused      anything else (401, 403, a redirect, ...)
   */
  async function fetchUpstream(target, validators) {
    const headers = new Headers();
    if (validators?.etag) headers.set('if-none-match', validators.etag);
    if (validators?.lastModified) headers.set('if-modified-since', validators.lastModified);

    // The timer covers the wait for response headers only; once they arrive
    // the body streams for as long as the phone takes to read it.
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), upstreamTimeoutMs);
    let response;
    try {
      response = await fetchImpl(upstreamUrl(origin, target), {
        method: 'GET',
        headers,
        redirect: 'manual',
        signal: controller.signal,
      });
    } catch {
      log({ event: 'upstream_failed', status: 0, bucket: target.bucket, reason: controller.signal.aborted ? 'timeout' : 'network' });
      return { kind: 'transient' };
    } finally {
      clearTimeout(timer);
    }

    const status = response.status;
    if (status === 200) {
      const declared = declaredImageType(response.headers.get('content-type'));
      if (declared === null) {
        await cancel(response);
        log({ event: 'upstream_not_image', bucket: target.bucket });
        return { kind: 'not_image' };
      }
      if (declared !== SNIFF) {
        return { kind: 'image', body: response.body, meta: metaFrom(response.headers, declared) };
      }
      // No usable type: the bytes have to say what they are.
      let bytes;
      try {
        bytes = await readBounded(response.body, MAX_SNIFF_BYTES);
      } catch {
        log({ event: 'upstream_failed', status: 0, bucket: target.bucket, reason: 'body' });
        return { kind: 'transient' };
      }
      const sniffed = bytes && sniffImageType(bytes);
      if (!sniffed) {
        log({ event: 'upstream_not_image', bucket: target.bucket });
        return { kind: 'not_image' };
      }
      const meta = metaFrom(response.headers, sniffed);
      return { kind: 'image', body: bytes, meta: { ...meta, length: String(bytes.byteLength) } };
    }

    await cancel(response);
    if (status === 304) return { kind: 'not_modified', meta: metaFrom(response.headers, null) };
    // Supabase answers a missing public object with 400 or 404.
    if (status === 400 || status === 404) return { kind: 'missing' };
    log({ event: 'upstream_failed', status, bucket: target.bucket });
    if (status >= 500 || status === 429) return { kind: 'transient' };
    return { kind: 'refused' };
  }

  // ── IMMUTABLE: post photos and thumbnails ─────────────────────────────────

  async function immutable(target, ctx) {
    const key = cacheKey(target);
    const hit = await lookup(key);
    if (hit) {
      if (hit.status === 404) {
        await cancel(hit);
        return missing('HIT');
      }
      const meta = storedMeta(hit);
      if (meta) return image(hit.body, meta, IMMUTABLE_CACHE_CONTROL, 'HIT');
      await cancel(hit);
    }

    const up = await fetchUpstream(target, null);
    if (up.kind === 'image') {
      const response = image(up.body, up.meta, IMMUTABLE_CACHE_CONTROL, 'MISS');
      store(ctx, key, response, up.meta, IMMUTABLE);
      return response;
    }
    if (up.kind === 'missing') {
      // The name is unique and is never written later, so the edge may
      // answer for it for ten minutes without asking Supabase again.
      later(ctx, 'put', () => cache.put(key, missing(null)));
      return missing('MISS');
    }
    if (up.kind === 'not_image') return notFound();
    return badGateway();
  }

  // ── MUTABLE: avatars, overwritten in place ────────────────────────────────

  async function mutable(target, ctx) {
    const key = cacheKey(target);
    let stored = await lookup(key);
    let meta = stored ? storedMeta(stored) : null;
    if (stored && !meta) {
      await cancel(stored);
      stored = null;
    }

    if (stored) {
      const age = now() - Number(stored.headers.get(STORED_AT_HEADER));
      // A far-future stamp is not trusted; it revalidates like an old one.
      if (Number.isFinite(age) && age > -FRESH_MS && age < FRESH_MS) {
        return image(stored.body, meta, MUTABLE_CLIENT_CACHE_CONTROL, 'HIT');
      }
    }

    const up = await fetchUpstream(target, stored ? meta : null);
    switch (up.kind) {
      case 'image': {
        if (stored) await cancel(stored);
        const response = image(up.body, up.meta, MUTABLE_CLIENT_CACHE_CONTROL, stored ? 'EXPIRED' : 'MISS');
        store(ctx, key, response, up.meta, target.kind);
        return response;
      }
      case 'not_modified': {
        if (!stored) return badGateway(); // a 304 to a request that asked for none
        // A 304 may carry fresher validators (RFC 9111 4.3.4); keep the bytes.
        const refreshed = { ...meta, etag: up.meta.etag ?? meta.etag, lastModified: up.meta.lastModified ?? meta.lastModified };
        const response = image(stored.body, refreshed, MUTABLE_CLIENT_CACHE_CONTROL, 'REVALIDATED');
        store(ctx, key, response, refreshed, target.kind);
        return response;
      }
      case 'transient':
        // stale-if-error: the stamp is left as it was, so the next request
        // asks Supabase again.
        if (stored) return image(stored.body, meta, MUTABLE_CLIENT_CACHE_CONTROL, 'STALE');
        return badGateway();
      default: {
        // missing (the avatar was removed), not_image, refused: Supabase no
        // longer serves this as a public photo, so neither does the edge.
        if (stored) {
          await cancel(stored);
          later(ctx, 'delete', () => cache.delete(key));
        }
        return up.kind === 'refused' ? badGateway() : notFound();
      }
    }
  }

  // ── routing ───────────────────────────────────────────────────────────────

  return {
    /**
     * @param {Request} request
     * @param {{waitUntil(p: Promise<unknown>): void}} [ctx]
     */
    async fetch(request, ctx) {
      if (request.method !== 'GET') return json(405, 'METHOD_NOT_ALLOWED', { allow: 'GET' });
      try {
        const url = new URL(request.url);
        const target = resolveImage(url.pathname, url.searchParams);
        if (!target) return notFound();
        const response = target.kind === IMMUTABLE ? await immutable(target, ctx) : await mutable(target, ctx);
        // One line per photo request, for `wrangler tail`: never a path or uid.
        log({
          event: 'served',
          status: response.status,
          cache: response.headers.get('cf-cache-status'),
          kind: target.kind,
          colo: request.cf?.colo ?? null,
        });
        return response;
      } catch (e) {
        log({ event: 'internal_error', detail: e?.name });
        return badGateway();
      }
    },
  };
}

/** A GET with no headers at all: two phones asking for one photo share it. */
function cacheKey(target) {
  return new Request(cacheKeyUrl(target), { method: 'GET' });
}

function metaFrom(headers, type) {
  const length = headers.get('content-length');
  return {
    type,
    length: length !== null && /^\d{1,10}$/.test(length) ? length : null,
    etag: headers.get('etag'),
    lastModified: headers.get('last-modified'),
  };
}

/** The whole body, or null as soon as it exceeds [limit] bytes. */
async function readBounded(body, limit) {
  if (!body) return new Uint8Array(0);
  const reader = body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      try {
        await reader.cancel();
      } catch {
        // Already closed.
      }
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

async function cancel(response) {
  try {
    await response.body?.cancel();
  } catch {
    // Nothing to release.
  }
}
