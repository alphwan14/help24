import PostalMime from 'postal-mime';
import { buildPayload, deliver } from './mail.js';

/** Larger than this is not read: it is forwarded (if a copy address is set) or refused. */
const MAX_RAW = 25 * 1024 * 1024;

/**
 * support@ and info@ help24.co.ke — Cloudflare Email Routing hands each email
 * here. In order:
 *
 *  1. The raw email is read once, into memory (a stream can be read only once).
 *  2. A copy goes to FORWARD_TO (the team's existing inbox), when set: the
 *     safety net while the Inbox is new. Forwarding never depends on step 4.
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

  let copied = false;
  if (forwardTo) {
    try {
      await message.forward(forwardTo);
      copied = true;
    } catch (e) {
      console.error('[help24-mail] copy to the team inbox failed:', e instanceof Error ? e.message : String(e));
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

/** A setting as text without surrounding whitespace; '' when unset. */
function setting(value) {
  return typeof value === 'string' ? value.trim() : '';
}

export default {
  email: (message, env) => handleEmail(message, env),
};
