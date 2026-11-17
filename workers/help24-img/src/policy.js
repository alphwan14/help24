// Pure decisions for img.help24.co.ke. No I/O lives here, so every rule about
// WHAT may be served, and how long it may be kept, is testable without a network.
//
// ALLOWLIST, NOT DENYLIST. A path is served only when it matches one of the
// RULES below exactly. Everything else is refused before any upstream call,
// which is what keeps the private buckets (chat-attachments, dispute-evidence,
// provider-verifications, support-attachments), the legacy chat prefix
// (post-images/chat_attachments/) and the diagnostic prefix (post-images/test/)
// out of reach: they are never named here, so no path can resolve to them.

/** The hostname the app loads photos from; the cache key is built on it. */
export const PUBLIC_ORIGIN = 'https://img.help24.co.ke';

/** Names written once (upsert false) and never reused: kept for a year. */
export const IMMUTABLE = 'immutable';
/** Names overwritten in place (upsert true): short cache with revalidation. */
export const MUTABLE = 'mutable';

/** The longest legitimate path is a profiles avatar with a 128-char uid
 *  (about 150 chars). Anything far beyond that is not a Help24 photo. */
export const MAX_PATH_LENGTH = 256;

const HEX = '[0-9a-fA-F]';
const UUID = `${HEX}{8}-${HEX}{4}-${HEX}{4}-${HEX}{4}-${HEX}{12}`;
/** A Firebase uid as it appears in an object key (older Supabase ids too). */
const UID = '[A-Za-z0-9_-]{1,128}';
/** "jpg" -> "[jJ][pP][gG]": the extension in any case, the folder names exact. */
const anyCase = (word) => [...word].map((c) => `[${c}${c.toUpperCase()}]`).join('');
const EXT = `(?:${['jpg', 'jpeg', 'png', 'gif', 'webp'].map(anyCase).join('|')})`;

/**
 * The only objects this Worker will ever fetch. Post photo names come from
 * Uuid().v4() in the app (lowercase), but the hex and the extension are matched
 * in any case so an older upload with different casing still loads; storage
 * keys are case-sensitive, so this cannot alias two objects.
 */
export const RULES = Object.freeze([
  // post-images/posts/<uuid>.<ext>: post photos (StorageService.uploadImage).
  Object.freeze({ bucket: 'post-images', pattern: new RegExp(`^posts/${UUID}\\.${EXT}$`), kind: IMMUTABLE }),
  // post-images/posts/<uuid>.thumb.jpg: the feed thumbnail made at upload.
  Object.freeze({ bucket: 'post-images', pattern: new RegExp(`^posts/${UUID}\\.thumb\\.jpg$`), kind: IMMUTABLE }),
  // post-images/avatars/<uid>.<ext>: older avatar uploads (upsert true).
  Object.freeze({ bucket: 'post-images', pattern: new RegExp(`^avatars/${UID}\\.${EXT}$`), kind: MUTABLE }),
  // profiles/<uid>/avatar.jpg: today's avatars (upsert true, ?t= cache buster).
  Object.freeze({ bucket: 'profiles', pattern: new RegExp(`^${UID}/avatar\\.jpg$`), kind: MUTABLE }),
]);

/** Characters a valid path can contain. No '%' at all, so no encoded slash,
 *  dot, backslash or control character survives; no '\' either. */
const PATH_CHARS = /^\/[A-Za-z0-9._\/-]+$/;
const CACHE_BUSTER = /^\d{1,20}$/;

/**
 * The object a request path names, or null when it is not one this Worker
 * serves.
 *
 * The URL parser has already resolved "." / ".." segments (including
 * %2e forms) and turned "\" into "/" before a Worker sees request.url; these
 * checks hold on the raw string too, so they do not depend on that.
 *
 * Only `t` survives from the query, only as 1 to 20 digits, and only for the
 * MUTABLE class, where it is the app's cache buster for an overwritten avatar.
 * An IMMUTABLE object cannot change under its name, so a `t` there could only
 * fan one photo out into many cache entries and upstream fetches.
 *
 * @param {string} pathname   e.g. "/profiles/<uid>/avatar.jpg"
 * @param {URLSearchParams} [searchParams]
 * @returns {null | {bucket: string, path: string, kind: string, t: string | null}}
 */
export function resolveImage(pathname, searchParams) {
  if (typeof pathname !== 'string' || pathname.length < 2 || pathname.length > MAX_PATH_LENGTH) return null;
  if (!PATH_CHARS.test(pathname)) return null;
  const segments = pathname.slice(1).split('/');
  if (segments.some((s) => s === '' || s === '.' || s === '..')) return null;
  const [bucket, ...rest] = segments;
  if (rest.length === 0) return null;
  const path = rest.join('/');
  const rule = RULES.find((r) => r.bucket === bucket && r.pattern.test(path));
  if (!rule) return null;
  let t = null;
  if (rule.kind === MUTABLE && searchParams) {
    const value = searchParams.get('t');
    if (value !== null && CACHE_BUSTER.test(value)) t = value;
  }
  return Object.freeze({ bucket, path, kind: rule.kind, t });
}

const query = (target) => (target.t === null ? '' : `?t=${target.t}`);

/** The cache key URL: built only from validated parts, never from the request. */
export function cacheKeyUrl(target) {
  return `${PUBLIC_ORIGIN}/${target.bucket}/${target.path}${query(target)}`;
}

/** The anonymous public-object URL. `t` goes along so Supabase's own CDN does
 *  not answer a new avatar with an old copy. */
export function upstreamUrl(supabaseOrigin, target) {
  return `${supabaseOrigin}/storage/v1/object/public/${target.bucket}/${target.path}${query(target)}`;
}

/** The https origin of SUPABASE_URL, or a thrown Error (fail closed). */
export function supabaseOrigin(value) {
  if (typeof value !== 'string' || value.length === 0) throw new Error('SUPABASE_URL is required');
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error('SUPABASE_URL is not a URL');
  }
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.pathname.replace(/\/+$/, '') !== '') {
    throw new Error('SUPABASE_URL must be a bare https origin');
  }
  return url.origin;
}

// ── content types ───────────────────────────────────────────────────────────

/** The only types ever served. Both public buckets accept uploads of exactly
 *  these, so anything else upstream is not a Help24 photo. */
export const IMAGE_TYPES = Object.freeze(['image/jpeg', 'image/png', 'image/gif', 'image/webp']);

/** declaredImageType's answer when the header says nothing useful. */
export const SNIFF = 'sniff';

/**
 * What to do with an upstream Content-Type: the normalised image type to pass
 * through, SNIFF when it is missing or application/octet-stream (some older
 * uploads were stored without a type), or null to refuse (text/html,
 * image/svg+xml, ... : anything that could run or render as a document).
 */
export function declaredImageType(value) {
  if (value === null || value === undefined) return SNIFF;
  const mime = String(value).split(';')[0].trim().toLowerCase();
  if (mime === '' || mime === 'application/octet-stream') return SNIFF;
  if (mime === 'image/jpg') return 'image/jpeg';
  return IMAGE_TYPES.includes(mime) ? mime : null;
}

/** The image type the first bytes prove, or null. */
export function sniffImageType(bytes) {
  const b = bytes;
  const at = (offset, ...sig) => b.length >= offset + sig.length && sig.every((v, i) => b[offset + i] === v);
  if (at(0, 0xff, 0xd8, 0xff)) return 'image/jpeg';
  if (at(0, 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)) return 'image/png';
  if (at(0, 0x47, 0x49, 0x46, 0x38, 0x37, 0x61) || at(0, 0x47, 0x49, 0x46, 0x38, 0x39, 0x61)) return 'image/gif';
  if (at(0, 0x52, 0x49, 0x46, 0x46) && at(8, 0x57, 0x45, 0x42, 0x50)) return 'image/webp';
  return null;
}

// ── cache lifetimes ─────────────────────────────────────────────────────────

/** IMMUTABLE: the same to the phone and at the edge. */
export const IMMUTABLE_CACHE_CONTROL = 'public, max-age=31536000, immutable';

/** IMMUTABLE names never appear later, so a miss may be remembered briefly. A
 *  thumbnail a backfill adds afterwards shows up within ten minutes. */
export const MISSING_CACHE_CONTROL = 'public, max-age=600';

/** MUTABLE: what the phone is told. A changed avatar shows within 5 minutes
 *  even for a URL without a new ?t=. */
export const MUTABLE_CLIENT_CACHE_CONTROL = 'public, max-age=300';

/** MUTABLE: how long the edge may hold a copy at all. It is revalidated once it
 *  is older than FRESH_MS, so this only bounds how long a stale copy can stand
 *  in while Supabase is failing. */
export const MUTABLE_STORED_CACHE_CONTROL = 'public, max-age=86400';

/** MUTABLE: a stored copy younger than this is served without asking upstream. */
export const FRESH_MS = 5 * 60 * 1000;

/** Internal header on a stored MUTABLE copy; never sent to a client. */
export const STORED_AT_HEADER = 'x-help24-stored-at';

/** Headers on every response this Worker sends. A photo is never a document:
 *  nothing in it may be sniffed into one, run or load anything. */
export const SECURITY_HEADERS = Object.freeze({
  'x-content-type-options': 'nosniff',
  'content-security-policy': "default-src 'none'; sandbox",
});
