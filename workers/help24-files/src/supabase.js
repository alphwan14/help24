// The only Supabase calls the Worker makes — four fixed shapes, nothing else.
//
// Nothing a client sends is ever turned into a Supabase path here. Ids are
// re-checked as uuids before they are interpolated into a PostgREST filter, the
// bucket must be one of the two this Worker knows, and an object key must
// already be in the canonical shape `policy.js` derives from a database row.
// So even a bug in the router could not make this a proxy into arbitrary
// storage paths or tables.
//
// The service key is sent ONLY to the configured Supabase origin, and never
// appears in anything returned to a caller: storage responses are consumed by
// the router, which copies a short allowlist of headers and the bytes.

import { LEGACY_BUCKET, PRIVATE_BUCKET, isUuid } from './policy.js';

export class UpstreamError extends Error {
  constructor(message) {
    super(message);
    this.name = 'UpstreamError';
  }
}

const MESSAGE_COLUMNS = 'id,chat_id,sender_id,type,content,attachment_url,deleted_for_everyone,chats(user1,user2)';
const KEY_RE = /^[0-9A-Za-z_-]{1,128}(\/[0-9A-Za-z_-]{1,128}){1,2}\.[A-Za-z]{3,4}$/;

/**
 * @param {object} options
 * @param {string} options.url          https://<ref>.supabase.co
 * @param {string} options.serviceKey   secret key (sb_secret_…) or legacy service_role JWT
 * @param {typeof fetch} [options.fetchImpl]
 */
export function createSupabase({ url, serviceKey, fetchImpl = fetch }) {
  if (typeof url !== 'string' || !/^https?:\/\/[^/]+$/.test(url.replace(/\/+$/, ''))) {
    throw new Error('createSupabase: url must be an origin');
  }
  if (typeof serviceKey !== 'string' || serviceKey.length < 20) throw new Error('createSupabase: serviceKey is required');
  const base = url.replace(/\/+$/, '');

  // A new-style secret key is not a JWT and is only accepted as `apikey`; the
  // gateway mints the internal service-role JWT itself. A legacy service_role
  // key is a JWT and is sent as both, which is what that gateway expects.
  const auth = { apikey: serviceKey };
  if (/^eyJ[\w-]*\.[\w-]+\.[\w-]+$/.test(serviceKey)) auth.authorization = `Bearer ${serviceKey}`;

  async function rest(pathAndQuery) {
    let res;
    try {
      res = await fetchImpl(`${base}/rest/v1/${pathAndQuery}`, { headers: { ...auth, accept: 'application/json' } });
    } catch {
      throw new UpstreamError('rest unreachable');
    }
    if (!res.ok) {
      await discard(res);
      throw new UpstreamError(`rest ${res.status}`);
    }
    let body;
    try {
      body = await res.json();
    } catch {
      throw new UpstreamError('rest body');
    }
    if (!Array.isArray(body)) throw new UpstreamError('rest shape');
    return body;
  }

  function objectPath(bucket, key) {
    if (bucket !== PRIVATE_BUCKET && bucket !== LEGACY_BUCKET) throw new UpstreamError('bucket refused');
    if (typeof key !== 'string' || !KEY_RE.test(key)) throw new UpstreamError('key refused');
    return `${bucket}/${key.split('/').map(encodeURIComponent).join('/')}`;
  }

  return {
    /** The project origin — `policy.js` needs it to recognise legacy public URLs. */
    url: base,

    /** One message with its chat's two participants embedded, or null. */
    async message(messageId) {
      if (!isUuid(messageId)) return null;
      const rows = await rest(
        `chat_messages?select=${MESSAGE_COLUMNS}&id=eq.${messageId.toLowerCase()}&limit=1`,
      );
      return rows[0] ?? null;
    },

    /** The chat's two participant uids, or null when there is no such chat. */
    async chatMembers(chatId) {
      if (!isUuid(chatId)) return null;
      const rows = await rest(`chats?select=user1,user2&id=eq.${chatId.toLowerCase()}&limit=1`);
      const chat = rows[0];
      if (!chat) return null;
      return [chat.user1, chat.user2].filter((u) => typeof u === 'string' && u.length > 0);
    },

    /**
     * The raw storage response for one object. The router reads its status,
     * an allowlist of headers and its body — never forwards it whole.
     */
    async getObject(bucket, key, { range = null, ifNoneMatch = null } = {}) {
      const headers = { ...auth };
      if (range) headers.range = range;
      if (ifNoneMatch) headers['if-none-match'] = ifNoneMatch;
      try {
        return await fetchImpl(`${base}/storage/v1/object/authenticated/${objectPath(bucket, key)}`, { headers });
      } catch (e) {
        if (e instanceof UpstreamError) throw e;
        throw new UpstreamError('storage unreachable');
      }
    },

    /**
     * Store bytes under a key that must not exist yet. 'stored' when written,
     * 'exists' when the key was already taken — for a key named by a message's
     * own id that means an earlier attempt of the same upload already landed.
     */
    async putObject(bucket, key, bytes, contentType) {
      let res;
      try {
        res = await fetchImpl(`${base}/storage/v1/object/${objectPath(bucket, key)}`, {
          method: 'POST',
          headers: { ...auth, 'content-type': contentType, 'x-upsert': 'false' },
          body: bytes,
        });
      } catch (e) {
        if (e instanceof UpstreamError) throw e;
        throw new UpstreamError('storage unreachable');
      }
      if (res.ok) {
        await discard(res);
        return 'stored';
      }
      const text = await res.text().catch(() => '');
      if (res.status === 409 || isDuplicate(text)) return 'exists';
      throw new UpstreamError(`storage put ${res.status}`);
    },
  };
}

/** Storage answers a taken key with HTTP 409, or (older versions) 400 + statusCode "409". */
function isDuplicate(text) {
  try {
    const body = JSON.parse(text);
    return String(body?.statusCode) === '409' || body?.error === 'Duplicate';
  } catch {
    return false;
  }
}

async function discard(res) {
  try {
    await res.body?.cancel();
  } catch {
    // Nothing to release.
  }
}
