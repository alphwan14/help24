import PostalMime from 'postal-mime';
import { buildPayload, deliver } from './mail.js';

/** Larger than this is not read: it is forwarded (if a copy address is set) or refused. */
const MAX_RAW = 25 * 1024 * 1024;

/**
 * support@ and info@ help24.co.ke — Cloudflare Email Routing hands each email
 * here. In order:
 *
 *  1. The raw email is read once, into memory (a stream can be read only once).
 *  2. A copy goes to each address in FORWARD_TO (the team's own inboxes), when
 *     set: the safety net while the Inbox is new. Never depends on step 4.
 *  3. The email is parsed (postal-mime) and turned into the backend's JSON.
 *  4. It is POSTed, signed, to SUPPORT_INBOUND_URL, with retries.
 *
 * Nothing is lost silently: if the backend cannot take it and no copy went
 * anywhere, the email is refused, so the sender's mail server tells them.
 * The Worker logs no addresses or content.
 */
export async function handleEmail(message, env, { deliverImpl = deliver } = {}) {
  // Secrets are pasted into the Cloudflare dashboard by hand, and a stray space
  // or newline in the signing key would fail every delivery. The backend trims
  // its copy of the key too, so both sides sign with the same bytes.
  const url = setting(env.SUPPORT_INBOUND_URL);
  const secret = setting(env.SUPPORT_INBOUND_SECRET);
  const forwardTo = setting(env.FORWARD_TO);

  let raw = null;
  if (message.rawSize <= MAX_RAW) {
    try {
      raw = await new Response(message.raw).arrayBuffer();
    } catch (e) {
      console.error('[help24-mail] could not read the message:', e instanceof Error ? e.message : String(e));
    }
  } else {
    console.error(`[help24-mail] message too large to read (${message.rawSize} bytes)`);
  }

  // One copy per address; one failing (say, not yet verified) never stops the others.
  let copied = false;
  for (const [i, address] of copyAddresses(forwardTo).entries()) {
    try {
      await message.forward(address);
      copied = true;
    } catch (e) {
      console.error(`[help24-mail] copy ${i + 1} to the team inbox failed:`, e instanceof Error ? e.message : String(e));
    }
  }
  const refuse = (reason) => {
    if (!copied) message.setReject(reason);
  };

  if (!url || !secret) {
    console.error('[help24-mail] SUPPORT_INBOUND_URL / SUPPORT_INBOUND_SECRET not set');
    return refuse('Help24 could not accept this message right now. Please try again later.');
  }
  if (!raw) return refuse('This message could not be read. Please send it without large attachments.');

  let json;
  try {
    const parsed = await PostalMime.parse(raw);
    json = buildPayload({ envelopeTo: message.to, parsed, headers: message.headers });
  } catch (e) {
    console.error('[help24-mail] could not parse the message:', e instanceof Error ? e.message : String(e));
    return refuse('Help24 could not read this message.');
  }
  if (!json.from.address) return refuse('Help24 could not read the sender of this message.');

  const result = await deliverImpl({ url, secret, json });
  if (!result.ok) {
    console.error(`[help24-mail] the Inbox did not take the message: status ${result.status} after ${result.attempts} attempts`);
    refuse('Help24 could not accept this message right now. Please try again later.');
  }
}

/** At most this many copies per email. */
const MAX_COPIES = 5;

/**
 * FORWARD_TO as a list: addresses separated by commas, semicolons or spaces,
 * each once (case-insensitively), at most MAX_COPIES. Each must be a verified
 * Email Routing destination, or Cloudflare refuses that copy.
 */
export function copyAddresses(value) {
  const seen = new Set();
  const out = [];
  for (const part of String(value ?? '').split(/[\s,;]+/)) {
    const address = part.trim();
    if (!address.includes('@') || seen.has(address.toLowerCase())) continue;
    seen.add(address.toLowerCase());
    out.push(address);
    if (out.length === MAX_COPIES) break;
  }
  return out;
}

/** A setting as text without surrounding whitespace; '' when unset. */
function setting(value) {
  return typeof value === 'string' ? value.trim() : '';
}

export default {
  email: (message, env) => handleEmail(message, env),
};
