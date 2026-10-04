// Firebase ID token verification, done in the Worker with WebCrypto.
//
// The same checks firebase-admin's verifyIdToken makes (and the backend's
// TokenVerifierService relies on), written out because the Admin SDK does not
// run in a Worker:
//
//   header   alg RS256, kid names one of Google's current securetoken keys
//   sig      RSASSA-PKCS1-v1_5 / SHA-256 over `<header>.<payload>`
//   claims   aud == project, iss == https://securetoken.google.com/<project>,
//            sub is a non-empty uid (≤ 128 chars), exp in the future,
//            iat and auth_time not in the future
//
// Revocation is not checked, exactly as on the backend: it would need a call to
// Firebase per request. A revoked session can open its own chat files until its
// token expires (at most an hour) — the same window every other Help24 surface
// already accepts.
//
// The outcome is always a value, never a throw, so the router can tell "this
// token is bad" (401) from "Google's keys could not be fetched" (503) without a
// try/catch — and never tells a signed-in user their session is bad because of
// an outage they cannot fix.

import { b64urlDecode } from './tokens.js';

export const GOOGLE_JWKS_URL =
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';

/** Tolerance for Google's clock running ahead of Cloudflare's, on iat/auth_time only. */
const CLOCK_SKEW_SECONDS = 60;
const MAX_TOKEN_LENGTH = 4096;
/** A kid we have never seen forces at most one key refetch per this interval,
 *  so a stream of junk kids cannot turn every request into a fetch to Google. */
const MIN_FORCED_REFRESH_MS = 60_000;
const DEFAULT_KEY_TTL_MS = 60 * 60 * 1000;

const decoder = new TextDecoder();
const encoder = new TextEncoder();

/**
 * @param {object} options
 * @param {string} options.projectId  Firebase project id (aud / iss).
 * @param {typeof fetch} [options.fetchImpl]
 * @param {() => number} [options.now]  milliseconds
 * @param {string} [options.jwksUrl]
 * @returns {(token: string) => Promise<{ok: true, uid: string} | {ok: false, reason: 'malformed'|'invalid'|'expired'|'unavailable'}>}
 */
export function createFirebaseVerifier({ projectId, fetchImpl = fetch, now = () => Date.now(), jwksUrl = GOOGLE_JWKS_URL }) {
  if (typeof projectId !== 'string' || !projectId) throw new Error('createFirebaseVerifier: projectId is required');
  const issuer = `https://securetoken.google.com/${projectId}`;

  /** kid → Promise<CryptoKey> */
  let keys = null;
  let keysExpireAt = 0;
  let lastForcedRefresh = 0;
  let inflight = null;

  async function loadKeys() {
    const res = await fetchImpl(jwksUrl, { headers: { accept: 'application/json' } });
    if (!res.ok) throw new Error(`jwks ${res.status}`);
    const body = await res.json();
    if (!body || !Array.isArray(body.keys)) throw new Error('jwks shape');
    const next = new Map();
    for (const jwk of body.keys) {
      if (!jwk || jwk.kty !== 'RSA' || typeof jwk.kid !== 'string' || !jwk.n || !jwk.e) continue;
      next.set(
        jwk.kid,
        crypto.subtle.importKey(
          'jwk',
          { kty: 'RSA', n: jwk.n, e: jwk.e, alg: 'RS256', ext: true },
          { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
          false,
          ['verify'],
        ),
      );
    }
    keys = next;
    keysExpireAt = now() + maxAgeMs(res.headers.get('cache-control'));
  }

  function refresh() {
    inflight ??= loadKeys().finally(() => {
      inflight = null;
    });
    return inflight;
  }

  async function keyFor(kid) {
    if (!keys || now() >= keysExpireAt) {
      try {
        await refresh();
      } catch (e) {
        // Google's keys live for days; a set we already hold stays usable
        // through a brief outage, retried at most once a minute.
        if (!keys) throw e;
        keysExpireAt = now() + MIN_FORCED_REFRESH_MS;
      }
    }
    if (!keys.has(kid) && now() - lastForcedRefresh >= MIN_FORCED_REFRESH_MS) {
      // Google rotated its keys since we last fetched them.
      lastForcedRefresh = now();
      try {
        await refresh();
      } catch {
        // Keep the set we have; this kid is simply unknown.
      }
    }
    return keys.get(kid) ?? null;
  }

  return async function verifyIdToken(token) {
    if (typeof token !== 'string' || token.length === 0 || token.length > MAX_TOKEN_LENGTH) {
      return { ok: false, reason: 'malformed' };
    }
    const parts = token.split('.');
    if (parts.length !== 3 || parts.some((p) => p.length === 0)) return { ok: false, reason: 'malformed' };

    let header;
    let payload;
    let signature;
    try {
      header = JSON.parse(decoder.decode(b64urlDecode(parts[0])));
      payload = JSON.parse(decoder.decode(b64urlDecode(parts[1])));
      signature = b64urlDecode(parts[2]);
    } catch {
      return { ok: false, reason: 'malformed' };
    }
    if (!header || header.alg !== 'RS256' || typeof header.kid !== 'string' || !header.kid) {
      return { ok: false, reason: 'invalid' };
    }
    if (!payload || typeof payload !== 'object') return { ok: false, reason: 'invalid' };

    let key;
    try {
      key = await keyFor(header.kid);
    } catch {
      return { ok: false, reason: 'unavailable' };
    }
    if (!key) return { ok: false, reason: 'invalid' };

    let valid = false;
    try {
      valid = await crypto.subtle.verify(
        'RSASSA-PKCS1-v1_5',
        await key,
        signature,
        encoder.encode(`${parts[0]}.${parts[1]}`),
      );
    } catch {
      valid = false;
    }
    if (!valid) return { ok: false, reason: 'invalid' };

    // Claims are read only after the signature has proven who wrote them.
    const nowSeconds = Math.floor(now() / 1000);
    if (payload.aud !== projectId || payload.iss !== issuer) return { ok: false, reason: 'invalid' };
    if (typeof payload.sub !== 'string' || payload.sub.length === 0 || payload.sub.length > 128) {
      return { ok: false, reason: 'invalid' };
    }
    if (typeof payload.iat !== 'number' || payload.iat > nowSeconds + CLOCK_SKEW_SECONDS) {
      return { ok: false, reason: 'invalid' };
    }
    if (typeof payload.auth_time !== 'number' || payload.auth_time > nowSeconds + CLOCK_SKEW_SECONDS) {
      return { ok: false, reason: 'invalid' };
    }
    if (typeof payload.exp !== 'number') return { ok: false, reason: 'invalid' };
    if (payload.exp <= nowSeconds) return { ok: false, reason: 'expired' };
    return { ok: true, uid: payload.sub };
  };
}

function maxAgeMs(cacheControl) {
  const match = /max-age=(\d+)/i.exec(cacheControl ?? '');
  if (!match) return DEFAULT_KEY_TTL_MS;
  // Bounded both ways: never cache a key set for less than a minute (a header
  // of max-age=0 would refetch per request) or longer than a day.
  return Math.min(Math.max(Number(match[1]) * 1000, 60_000), 24 * 60 * 60 * 1000);
}
