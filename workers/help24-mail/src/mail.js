/**
 * The parts of the mail Worker that need no Cloudflare runtime: turning a
 * parsed email into what the backend expects, spotting automated mail,
 * signing, and delivering with retries. src/index.js wires them to the
 * Email Routing event.
 */

/** Longest text handed to the backend; it keeps 20k of the new part and 60k in all. */
export const MAX_TEXT = 40000;

/** Mail that answers mail: never treated as a member writing in. */
export function isAutomated(headers, fromAddress) {
  const get = (name) => (headers.get(name) ?? '').toLowerCase();
  const auto = get('auto-submitted');
  if (auto && auto !== 'no') return true;
  if (/\b(bulk|junk|list|auto_reply)\b/.test(get('precedence'))) return true;
  if (get('x-autoreply') || get('x-autorespond') || get('x-auto-response-suppress').includes('all')) return true;
  if (get('list-id') || get('list-unsubscribe')) return true;
  if (get('content-type').includes('multipart/report')) return true;
  return /^(mailer-daemon|postmaster|no-?reply|do-?not-?reply)@/i.test(fromAddress ?? '');
}

/** HTML to readable text, for an email that has no plain-text part. */
export function htmlToText(html) {
  return String(html ?? '')
    .replace(/<(style|script|head)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|li|tr|h[1-6]|blockquote)>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/[ \t]+/g, ' ')
    .replace(/ *\n */g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/**
 * The JSON the backend's POST /support/inbound-email reads
 * (backend/src/support/support-rules.ts parseInbound).
 *
 * `envelopeTo` is the address Email Routing delivered to (always ours);
 * `parsed` is postal-mime's result; `headers` the raw message headers.
 */
export function buildPayload({ envelopeTo, parsed, headers }) {
  const from = parsed.from ?? {};
  const fromAddress = String(from.address ?? '').trim().toLowerCase();
  const recipients = [envelopeTo, ...(parsed.to ?? []), ...(parsed.cc ?? [])]
    .map((r) => (typeof r === 'string' ? r : r?.address))
    .filter(Boolean)
    .map((a) => String(a).trim().toLowerCase());
  const text = (parsed.text && parsed.text.trim()) ? parsed.text : htmlToText(parsed.html);
  const references = String(parsed.references ?? '')
    .split(/\s+/)
    .map((r) => r.trim())
    .filter(Boolean);
  const authResults = ['authentication-results', 'arc-authentication-results']
    .map((h) => headers.get(h))
    .filter(Boolean);
  return {
    from: { address: fromAddress, name: from.name ? String(from.name).slice(0, 120) : null },
    to: [...new Set(recipients)].slice(0, 50),
    subject: String(parsed.subject ?? '').slice(0, 500),
    text: String(text ?? '').slice(0, MAX_TEXT),
    messageId: parsed.messageId ?? null,
    inReplyTo: parsed.inReplyTo ?? null,
    references: references.slice(0, 50),
    authResults: authResults.slice(0, 10),
    attachments: Array.isArray(parsed.attachments) ? parsed.attachments.length : 0,
    automated: isAutomated(headers, fromAddress),
  };
}

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');

/** Base64 of UTF-8 JSON, without the btoa Latin-1 trap. */
export function toBase64(json) {
  const bytes = new TextEncoder().encode(JSON.stringify(json));
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

/** The body the backend checks: hex HMAC-SHA256 over "<timestamp>.<payload>". */
export async function signedBody(secret, json, nowSeconds = Math.floor(Date.now() / 1000)) {
  const payload = toBase64(json);
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${nowSeconds}.${payload}`));
  return { timestamp: nowSeconds, payload, signature: hex(sig) };
}

/**
 * POST to the backend, retrying what a retry can fix: network errors, 429 and
 * 5xx (a cold start on Render answers late). A 4xx other than 429 is final:
 * the request itself is wrong and sending it again will not help.
 * Returns { ok, status, attempts }.
 */
export async function deliver({ url, secret, json, fetchImpl = fetch, waits = [2000, 6000], sleep = (ms) => new Promise((r) => setTimeout(r, ms)) }) {
  let status = 0;
  for (let attempt = 0; attempt <= waits.length; attempt++) {
    if (attempt > 0) await sleep(waits[attempt - 1]);
    try {
      // Signed per attempt: a delay must not push the signature past its window.
      const body = await signedBody(secret, json);
      const res = await fetchImpl(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      status = res.status;
      if (res.ok) return { ok: true, status, attempts: attempt + 1 };
      if (status >= 400 && status < 500 && status !== 429) return { ok: false, status, attempts: attempt + 1 };
    } catch {
      status = 0;
    }
  }
  return { ok: false, status, attempts: waits.length + 1 };
}
