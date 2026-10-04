// Short-lived, signed capabilities for opening ONE document in a browser.
//
// Why these exist at all: a PDF opened from the app lands in Chrome, and the app
// cannot attach an Authorization header to a browser navigation. So the app asks
// the Worker (with its Firebase token) for a link, and the link carries a signed
// token instead. Two kinds, never interchangeable:
//
//   'l' LINK   — in the URL, valid 2 minutes, ONE use (its nonce is burnt on
//                first use). Exchanged immediately for a cookie and stripped
//                from the address bar by a redirect.
//   'c' COOKIE — HttpOnly, path-scoped to that one document, valid 10 minutes.
//                Lets the viewer re-request the file (range reads, "download")
//                without the link token ever being needed again.
//
// Neither carries the user id. Each carries a keyed TAG of it, so the Worker can
// re-check "is this person still a participant?" on every use without the uid
// appearing in a URL, a cookie, a log or browser history.

const encoder = new TextEncoder();
const keyCache = new Map();

export const LINK_TTL_SECONDS = 120;
export const COOKIE_TTL_SECONDS = 600;
export const COOKIE_NAME = 'h24doc';
const MAX_TOKEN_LENGTH = 512;

export function b64urlEncode(bytes) {
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function b64urlDecode(text) {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) throw new Error('not base64url');
  const pad = text.length % 4 === 0 ? '' : '='.repeat(4 - (text.length % 4));
  const bin = atob(text.replace(/-/g, '+').replace(/_/g, '/') + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function hmacKey(secret) {
  let key = keyCache.get(secret);
  if (!key) {
    key = crypto.subtle.importKey(
      'raw',
      encoder.encode(secret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign', 'verify'],
    );
    keyCache.set(secret, key);
  }
  return key;
}

/** `<payload>.<signature>`, both base64url. Domain-separated from member tags. */
export async function signToken(secret, payload) {
  const body = b64urlEncode(encoder.encode(JSON.stringify(payload)));
  const sig = await crypto.subtle.sign('HMAC', await hmacKey(secret), encoder.encode(`tok:${body}`));
  return `${body}.${b64urlEncode(new Uint8Array(sig))}`;
}

/** The verified payload, or null. Constant-time via WebCrypto verify. */
export async function verifyToken(secret, token) {
  if (typeof token !== 'string' || token.length === 0 || token.length > MAX_TOKEN_LENGTH) return null;
  const dot = token.indexOf('.');
  if (dot <= 0 || dot !== token.lastIndexOf('.')) return null;
  const body = token.slice(0, dot);
  let sig;
  try {
    sig = b64urlDecode(token.slice(dot + 1));
  } catch {
    return null;
  }
  const ok = await crypto.subtle.verify('HMAC', await hmacKey(secret), sig, encoder.encode(`tok:${body}`));
  if (!ok) return null;
  try {
    const payload = JSON.parse(new TextDecoder().decode(b64urlDecode(body)));
    return payload && typeof payload === 'object' ? payload : null;
  } catch {
    return null;
  }
}

/** A keyed, non-reversible tag of a user id. */
export async function memberTag(secret, uid) {
  const sig = await crypto.subtle.sign('HMAC', await hmacKey(secret), encoder.encode(`member:${uid}`));
  return b64urlEncode(new Uint8Array(sig)).slice(0, 27);
}

export function randomNonce() {
  return b64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
}

/** Validate a decoded token's shape for the given kind and document. */
export function tokenAcceptable(payload, { kind, messageId, nowSeconds }) {
  if (!payload || payload.v !== 1 || payload.k !== kind) return false;
  if (typeof payload.m !== 'string' || payload.m.toLowerCase() !== messageId.toLowerCase()) return false;
  if (typeof payload.u !== 'string' || payload.u.length < 16) return false;
  if (typeof payload.e !== 'number' || payload.e <= nowSeconds) return false;
  if (kind === 'l' && (typeof payload.n !== 'string' || payload.n.length < 16)) return false;
  return true;
}

/** Every value of our cookie in a Cookie header (path scoping may send more than one). */
export function readCookies(header, name = COOKIE_NAME) {
  if (typeof header !== 'string' || !header) return [];
  const out = [];
  for (const part of header.split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() === name) out.push(part.slice(eq + 1).trim());
  }
  return out;
}
