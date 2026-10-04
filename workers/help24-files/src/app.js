// files.help24.co.ke — the only way a chat attachment leaves storage.
//
// Three routes, nothing else:
//
//   PUT  /u/<chatId>/<messageId>   store a new attachment (Firebase ID token)
//   GET  /d/<messageId>            read one (Firebase ID token, or the
//   HEAD /d/<messageId>              document cookie a browser link set)
//   POST /links/<messageId>        mint a one-time browser link (Firebase ID token)
//
// THE RULE EVERY READ KEEPS: the caller names a MESSAGE, never a file. The
// message row is loaded with the service key, the caller must be one of the
// two participants of that row's chat, the row must not be deleted for
// everyone, and the only object that can be served is the one `policy.js`
// derives from the row itself. There is no input that selects a bucket, a key
// or a host, so this cannot be pointed at anything but a chat file its caller
// is allowed to see.
//
// Not-a-participant and no-such-message are the same 404, byte for byte, so
// the endpoint answers nothing about which message ids exist.

import {
  MAX_ATTACHMENT_BYTES,
  PRIVATE_BUCKET,
  SENDER_RE,
  TYPES,
  bytesMatchType,
  contentDisposition,
  decide,
  extForContentType,
  participantsOf,
  privateKey,
  privateRef,
  safeRange,
} from './policy.js';
import {
  COOKIE_NAME,
  COOKIE_TTL_SECONDS,
  LINK_TTL_SECONDS,
  memberTag,
  randomNonce,
  readCookies,
  signToken,
  tokenAcceptable,
  verifyToken,
} from './tokens.js';
import { UpstreamError } from './supabase.js';

const UUID = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
const DOWNLOAD_RE = new RegExp(`^/d/(${UUID})$`);
const LINK_RE = new RegExp(`^/links/(${UUID})$`);
const UPLOAD_RE = new RegExp(`^/u/(${UUID})/(${UUID})$`);

/** How long the app may keep a photo it fetched with its own token. The bytes
 *  under a message id never change (uploads cannot overwrite), so a week is
 *  safe; it is not longer so a deleted message's photo ages out of the cache. */
const APP_CACHE_SECONDS = 7 * 24 * 60 * 60;

const COMMON_HEADERS = Object.freeze({
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
  'strict-transport-security': 'max-age=31536000',
});
/** For anything that is not a PDF: nothing in the response may run or load. */
const LOCKED_CSP = "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; sandbox";

/**
 * @param {object} deps
 * @param {(token: string) => Promise<{ok: boolean, uid?: string, reason?: string}>} deps.verifyIdToken
 * @param {ReturnType<import('./supabase.js').createSupabase>} deps.supabase
 * @param {{burn(nonce: string): Promise<boolean>}} deps.nonces
 *        true the FIRST time a nonce is burnt, false ever after — atomically
 *        (a Durable Object in production; see nonce-store.js)
 * @param {string} deps.signingSecret
 * @param {{upload?: Limiter, link?: Limiter}} [deps.limits]  per-user rate limits
 * @param {() => number} [deps.now]           milliseconds
 * @param {(event: object) => void} [deps.log] never receives a token, uid or full id
 * @param {string} [deps.publicOrigin]       origin to put in minted links (default: the request's)
 *
 * @typedef {{limit(opts: {key: string}): Promise<{success: boolean}>}} Limiter
 */
export function createApp({ verifyIdToken, supabase, nonces, signingSecret, limits = {}, now = () => Date.now(), log = () => {}, publicOrigin }) {
  if (typeof signingSecret !== 'string' || signingSecret.length < 32) {
    throw new Error('createApp: signingSecret must be at least 32 characters');
  }
  const nowSeconds = () => Math.floor(now() / 1000);

  // ── responses ─────────────────────────────────────────────────────────────

  function json(status, body, extra = {}) {
    return new Response(JSON.stringify(body), {
      status,
      headers: {
        ...COMMON_HEADERS,
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
        'content-security-policy': LOCKED_CSP,
        ...extra,
      },
    });
  }

  const PAGES = {
    401: ['Link expired', 'This link has expired or was already used. Go back to Help24 and open the file again.'],
    404: ['Not available', "This file isn't available. It may have been removed, or you may not have access to it."],
    410: ['File deleted', 'This file was deleted by its sender.'],
    503: ['Try again', "We couldn't load this file right now. Please try again in a moment."],
  };

  /** What a person in a browser sees: plain words, no codes, nothing internal. */
  function page(status) {
    const [title, text] = PAGES[status] ?? PAGES[404];
    const html =
      `<!doctype html><html lang="en"><head><meta charset="utf-8">` +
      `<meta name="viewport" content="width=device-width,initial-scale=1">` +
      `<title>${title} · Help24</title><style>body{font:16px/1.5 system-ui,sans-serif;` +
      `margin:0;padding:48px 24px;color:#1a1a1a;background:#fafafa}main{max-width:420px;margin:0 auto}` +
      `h1{font-size:20px;margin:0 0 8px}p{margin:0;color:#555}</style></head>` +
      `<body><main><h1>${title}</h1><p>${text}</p></main></body></html>`;
    return new Response(html, {
      status,
      headers: {
        ...COMMON_HEADERS,
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
        'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
      },
    });
  }

  const notFound = () => json(404, { code: 'NOT_FOUND' });

  /** Whether [uid] may do one more [kind] now. No limiter bound → no limit. */
  async function withinLimit(kind, uid) {
    const limiter = limits[kind];
    if (!limiter) return true;
    const { success } = await limiter.limit({ key: uid });
    if (!success) log({ event: 'rate_limited', route: kind });
    return success;
  }
  const tooMany = () => json(429, { code: 'RATE_LIMITED' }, { 'retry-after': '60' });

  // ── identity ──────────────────────────────────────────────────────────────

  /** The verified uid from `Authorization: Bearer <Firebase ID token>`. */
  async function bearer(request) {
    const header = request.headers.get('authorization');
    if (header === null) return { kind: 'none' };
    const match = /^Bearer ([A-Za-z0-9._-]{1,4096})$/.exec(header.trim());
    if (!match) return { kind: 'refused', response: json(401, { code: 'UNAUTHENTICATED' }) };
    const result = await verifyIdToken(match[1]);
    if (result.ok) return { kind: 'uid', uid: result.uid };
    if (result.reason === 'unavailable') return { kind: 'refused', response: json(503, { code: 'UNAVAILABLE' }) };
    // TOKEN_EXPIRED is the contract the app's API client refreshes and replays on.
    if (result.reason === 'expired') return { kind: 'refused', response: json(401, { code: 'TOKEN_EXPIRED' }) };
    return { kind: 'refused', response: json(401, { code: 'UNAUTHENTICATED' }) };
  }

  /**
   * Load the message and decide, for a caller known either by uid (a verified
   * token) or by member tag (a signed link or cookie, which never carry a uid).
   * Membership is re-checked against the chat AS IT IS NOW on every request.
   */
  async function access(messageId, principal) {
    const row = await supabase.message(messageId);
    const members = participantsOf(row);
    let isMember = false;
    if (principal.uid) {
      isMember = members.includes(principal.uid);
    } else if (principal.tag) {
      for (const uid of members) {
        if (sameString(await memberTag(signingSecret, uid), principal.tag)) isMember = true;
      }
    }
    return decide(row, isMember, supabase.url);
  }

  // ── GET|HEAD /d/<messageId> ───────────────────────────────────────────────

  async function download(request, messageId, url) {
    const linkToken = url.searchParams.get('t');
    if (linkToken !== null) {
      if (request.method !== 'GET') return json(405, { code: 'METHOD_NOT_ALLOWED' }, { allow: 'GET' });
      return exchangeLink(messageId, linkToken);
    }

    const who = await bearer(request);
    if (who.kind === 'refused') return who.response;

    if (who.kind === 'uid') {
      const decision = await access(messageId, { uid: who.uid });
      if (decision.status === 'gone') return json(410, { code: 'GONE' });
      if (decision.status !== 'ok') return notFound();
      return serve(request, decision, { browser: false });
    }

    // No token: only a document cookie, scoped to this one document, will do.
    const nowS = nowSeconds();
    let tag = null;
    for (const value of readCookies(request.headers.get('cookie'))) {
      const payload = await verifyToken(signingSecret, value);
      if (tokenAcceptable(payload, { kind: 'c', messageId, nowSeconds: nowS })) {
        tag = payload.u;
        break;
      }
    }
    if (!tag) return page(401);
    const decision = await access(messageId, { tag });
    if (decision.status === 'gone') return page(410);
    if (decision.status !== 'ok') return page(404);
    return serve(request, decision, { browser: true });
  }

  /**
   * A browser arriving with a one-time link. The link is burnt FIRST — before
   * anything else can fail — so it never works twice, then exchanged for a
   * cookie scoped to this one document, and the browser is sent to the clean
   * URL so the link is not left sitting in the address bar.
   */
  async function exchangeLink(messageId, linkToken) {
    const nowS = nowSeconds();
    const payload = await verifyToken(signingSecret, linkToken);
    if (!tokenAcceptable(payload, { kind: 'l', messageId, nowSeconds: nowS })) return page(401);

    // Only a genuine, unexpired link reaches the store, so nobody can make it
    // remember nonces of their own invention.
    if (!(await nonces.burn(payload.n))) {
      log({ event: 'link_replayed' });
      return page(401);
    }

    const decision = await access(messageId, { tag: payload.u });
    if (decision.status === 'gone') return page(410);
    if (decision.status !== 'ok') return page(404);

    const id = messageId.toLowerCase();
    const cookie = await signToken(signingSecret, { v: 1, k: 'c', m: id, u: payload.u, e: nowS + COOKIE_TTL_SECONDS });
    return new Response(null, {
      status: 303,
      headers: {
        ...COMMON_HEADERS,
        location: `/d/${id}`,
        'cache-control': 'no-store',
        'set-cookie': `${COOKIE_NAME}=${cookie}; Path=/d/${id}; Max-Age=${COOKIE_TTL_SECONDS}; HttpOnly; Secure; SameSite=Lax`,
      },
    });
  }

  /** Stream the object a decision allows, with headers this Worker chooses. */
  async function serve(request, decision, { browser }) {
    const { object, filename } = decision;
    const type = TYPES[object.ext];
    const inm = request.headers.get('if-none-match');
    const upstream = await supabase.getObject(object.bucket, object.key, {
      range: safeRange(request.headers.get('range')),
      ifNoneMatch: inm && inm.length <= 200 && !browser ? inm : null,
    });
    const status = upstream.status;

    const headers = new Headers({
      ...COMMON_HEADERS,
      'content-type': type.mime,
      'content-disposition': contentDisposition(filename, type.inline),
      'accept-ranges': 'bytes',
      'cross-origin-resource-policy': 'same-origin',
      // A browser session holds the file only as long as it is open; the app
      // keeps it in its own private cache.
      'cache-control': browser ? 'private, no-store' : `private, max-age=${APP_CACHE_SECONDS}`,
    });
    // Chrome's PDF viewer must be free to render a PDF; nothing else needs to run.
    if (object.ext !== 'pdf') headers.set('content-security-policy', LOCKED_CSP);
    for (const name of ['content-length', 'content-range', 'etag', 'last-modified']) {
      const value = upstream.headers.get(name);
      if (value !== null) headers.set(name, value);
    }

    if (status === 304) {
      await cancel(upstream);
      headers.delete('content-length');
      return new Response(null, { status: 304, headers });
    }
    if (status === 416) {
      await cancel(upstream);
      headers.delete('content-length');
      return new Response(null, { status: 416, headers });
    }
    if (status === 400 || status === 404) {
      // The row points at an object that is not there (never uploaded, or not
      // yet migrated). Same answer as any other missing file.
      await cancel(upstream);
      log({ event: 'object_missing', legacy: object.legacy });
      return browser ? page(404) : notFound();
    }
    if (status !== 200 && status !== 206) {
      await cancel(upstream);
      throw new UpstreamError(`storage get ${status}`);
    }
    if (request.method === 'HEAD') {
      await cancel(upstream);
      return new Response(null, { status, headers });
    }
    return new Response(upstream.body, { status, headers });
  }

  // ── POST /links/<messageId> ───────────────────────────────────────────────

  async function mintLink(request, messageId, url) {
    const who = await bearer(request);
    if (who.kind === 'refused') return who.response;
    if (who.kind !== 'uid') return json(401, { code: 'UNAUTHENTICATED' });
    if (!(await withinLimit('link', who.uid))) return tooMany();

    const decision = await access(messageId, { uid: who.uid });
    if (decision.status === 'gone') return json(410, { code: 'GONE' });
    if (decision.status !== 'ok') return notFound();

    const id = messageId.toLowerCase();
    const token = await signToken(signingSecret, {
      v: 1,
      k: 'l',
      m: id,
      u: await memberTag(signingSecret, who.uid),
      e: nowSeconds() + LINK_TTL_SECONDS,
      n: randomNonce(),
    });
    const origin = publicOrigin ?? url.origin;
    return json(200, { url: `${origin}/d/${id}?t=${token}`, expires_in: LINK_TTL_SECONDS });
  }

  // ── PUT /u/<chatId>/<messageId> ───────────────────────────────────────────

  async function upload(request, chatId, messageId) {
    const who = await bearer(request);
    if (who.kind === 'refused') return who.response;
    if (who.kind !== 'uid') return json(401, { code: 'UNAUTHENTICATED' });
    // The uid names the uploader's folder; one that cannot be a key segment
    // cannot upload (Firebase uids always can).
    if (!SENDER_RE.test(who.uid)) return json(400, { code: 'UNSUPPORTED_ACCOUNT' });
    if (!(await withinLimit('upload', who.uid))) return tooMany();

    const ext = extForContentType(request.headers.get('content-type'));
    if (!ext) return json(415, { code: 'UNSUPPORTED_TYPE' });
    const declared = request.headers.get('content-length');
    if (declared === null || !/^\d{1,9}$/.test(declared)) return json(411, { code: 'LENGTH_REQUIRED' });
    const length = Number(declared);
    if (length === 0) return json(400, { code: 'EMPTY' });
    if (length > MAX_ATTACHMENT_BYTES) return json(413, { code: 'TOO_LARGE' });

    // Membership before a single byte is read: a stranger's upload costs
    // nothing but one row lookup.
    const members = await supabase.chatMembers(chatId);
    if (!members || !members.includes(who.uid)) return notFound();

    const bytes = await readBounded(request.body, MAX_ATTACHMENT_BYTES);
    if (bytes === null) return json(413, { code: 'TOO_LARGE' });
    if (bytes.length !== length) return json(400, { code: 'LENGTH_MISMATCH' });
    if (!bytesMatchType(ext, bytes)) return json(415, { code: 'CONTENT_MISMATCH' });

    // Stored under the UPLOADER's folder: a read serves only the folder of the
    // row's sender, so this file can never be shown as someone else's.
    const outcome = await supabase.putObject(PRIVATE_BUCKET, privateKey(chatId, who.uid, messageId, ext), bytes, TYPES[ext].mime);
    return json(outcome === 'stored' ? 201 : 200, {
      ref: privateRef(chatId, messageId, ext),
      stored: outcome === 'stored',
    });
  }

  // ── routing ───────────────────────────────────────────────────────────────

  async function route(request) {
    const url = new URL(request.url);
    const path = url.pathname;
    let m;
    if ((m = DOWNLOAD_RE.exec(path))) {
      if (request.method !== 'GET' && request.method !== 'HEAD') {
        return json(405, { code: 'METHOD_NOT_ALLOWED' }, { allow: 'GET, HEAD' });
      }
      return download(request, m[1], url);
    }
    if ((m = LINK_RE.exec(path))) {
      if (request.method !== 'POST') return json(405, { code: 'METHOD_NOT_ALLOWED' }, { allow: 'POST' });
      return mintLink(request, m[1], url);
    }
    if ((m = UPLOAD_RE.exec(path))) {
      if (request.method !== 'PUT') return json(405, { code: 'METHOD_NOT_ALLOWED' }, { allow: 'PUT' });
      return upload(request, m[1], m[2]);
    }
    return notFound();
  }

  return {
    async fetch(request) {
      const kind = routeKind(request);
      try {
        const response = await route(request);
        log({ event: 'request', route: kind, method: request.method, status: response.status });
        return response;
      } catch (e) {
        // Upstream detail (statuses, bodies, hostnames) stays in the log; the
        // caller learns only that it should try again.
        const upstream = e instanceof UpstreamError;
        log({ event: 'error', route: kind, kind: upstream ? 'upstream' : 'internal', detail: upstream ? e.message : e?.name });
        const browserNavigation = kind === 'd' && !request.headers.get('authorization');
        if (browserNavigation) return page(503);
        return json(503, { code: 'UNAVAILABLE' });
      }
    },
  };
}

/** Which route a request was for — for logs, which never see ids or tokens. */
function routeKind(request) {
  try {
    const path = new URL(request.url).pathname;
    if (path.startsWith('/d/')) return 'd';
    if (path.startsWith('/links/')) return 'links';
    if (path.startsWith('/u/')) return 'u';
  } catch {
    // Fall through.
  }
  return 'other';
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

function sameString(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
