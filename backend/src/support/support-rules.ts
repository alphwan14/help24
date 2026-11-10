import { createHmac, randomInt, timingSafeEqual } from 'crypto';

/**
 * The support Inbox's rules, kept free of I/O so each can be tested on its own:
 * references, which address is which inbox, trimming quoted history, the
 * inbound signature, and the reply email's subject and body.
 */

/** No 0/O, 1/I: a reference is read aloud and typed back. */
const REF_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const REF_PATTERN = /\[(H24-[A-HJ-NP-Z2-9]{6})\]/;

export function makeRef(): string {
  let out = 'H24-';
  for (let i = 0; i < 6; i++) out += REF_ALPHABET[randomInt(REF_ALPHABET.length)];
  return out;
}

/** The reference a subject carries ("Re: Payout [H24-7K3QXP]"), if any. */
export function refInSubject(subject: string): string | null {
  return REF_PATTERN.exec(subject ?? '')?.[1] ?? null;
}

/** A subject without our reference and without any "Re:"/"Fwd:" prefixes. */
function bareSubject(subject: string): string {
  let s = (subject ?? '').replace(REF_PATTERN, ' ');
  for (;;) {
    const next = s.replace(/^\s*(re|fw|fwd|aw|sv|wg)\s*(\[\d+\])?\s*:\s*/i, '');
    if (next === s) break;
    s = next;
  }
  return s.replace(/\s+/g, ' ').trim();
}

/**
 * For comparing two messages of the same thread:
 * "RE: Fwd: Payout [H24-7K3QXP]" → "payout".
 */
export function normalizeSubject(subject: string): string {
  return bareSubject(subject).toLowerCase();
}

/** The subject a thread keeps: the member's own, without prefixes, never empty. */
export function threadSubject(subject: string): string {
  return (bareSubject(subject) || 'No subject').slice(0, 200);
}

/** The subject of our reply: "Re: <subject> [H24-XXXXXX]". */
export function replySubject(subject: string, ref: string): string {
  return `Re: ${threadSubject(subject)} [${ref}]`;
}

export type InboxLabel = 'support' | 'general';

/**
 * Which inbox an email was sent to. info@ is General; support@ and anything
 * else at help24.co.ke is Support. Null when no help24.co.ke address is among
 * the recipients (the worker should not have sent it).
 */
export function labelFor(recipients: string[]): InboxLabel | null {
  const ours = recipients
    .map((r) => r.trim().toLowerCase())
    .filter((r) => r.endsWith('@help24.co.ke'));
  if (ours.length === 0) return null;
  const local = (a: string) => a.split('@')[0].split('+')[0];
  if (ours.some((a) => local(a) === 'support')) return 'support';
  if (ours.some((a) => local(a) === 'info')) return 'general';
  return 'support';
}

/**
 * The new part of a reply: everything above the first line where the mail
 * client starts quoting ("On Tue, … wrote:", "-----Original Message-----",
 * Outlook's "From: … Sent:" block, or a run of "> " lines). Returns the whole
 * text when nothing new would be left.
 */
export function stripQuotedReply(text: string): string {
  const lines = (text ?? '').replace(/\r\n?/g, '\n').split('\n');
  let cut = lines.length;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    const next = (lines[i + 1] ?? '').trim();
    const startsQuote =
      /^-{2,}\s*original message\s*-{2,}$/i.test(line) ||
      /^_{5,}$/.test(line) ||
      // "On Tue, 4 Nov 2026 at 10:02, Help24 Support <support@…> wrote:" — may wrap onto two lines.
      (/^on\b.*\bwrote:\s*$/i.test(line) && line.length < 300) ||
      (/^on\b/i.test(line) && /\bwrote:\s*$/i.test(next) && (line + next).length < 300) ||
      (/^from:\s.+/i.test(line) && /^(sent|date):\s/i.test(next)) ||
      (line.startsWith('>') && lines.slice(i).every((l) => l.trim() === '' || l.trim().startsWith('>')));
    if (startsQuote) {
      cut = i;
      break;
    }
  }
  const fresh = lines.slice(0, cut).join('\n').replace(/\n{3,}/g, '\n\n').trim();
  return fresh || (text ?? '').trim();
}

/**
 * Whether an Authentication-Results header vouches for the sender's domain:
 * DMARC passed, or DKIM passed for that very domain. Null when there is no
 * verdict to read (the Inbox then says the sender is not verified).
 */
export function senderVerified(authResults: string[], fromAddress: string): boolean | null {
  const domain = fromAddress.split('@')[1]?.toLowerCase();
  if (!domain || authResults.length === 0) return null;
  const all = authResults.join(';').toLowerCase();
  if (/\bdmarc=pass\b/.test(all)) return true;
  const dkim = all.match(/dkim=pass[^;]*header\.(?:d|i)=@?([a-z0-9.-]+)/g) ?? [];
  if (dkim.some((m) => m.endsWith(domain) || m.endsWith(`.${domain}`))) return true;
  if (/\b(dmarc|dkim|spf)=(pass|fail|softfail|none|neutral|temperror|permerror)\b/.test(all)) return false;
  return null;
}

/** How long the Worker's signature stays acceptable. */
export const INBOUND_MAX_AGE_SECONDS = 300;

/**
 * Signature of an inbound delivery from workers/help24-mail:
 * hex HMAC-SHA256 over "<timestamp>.<payload>", where payload is the base64
 * of the email's JSON. The backend checks the very string the Worker signed,
 * so no re-encoding can break it.
 */
export function signInbound(secret: string, timestamp: number, payload: string): string {
  return createHmac('sha256', secret).update(`${timestamp}.${payload}`).digest('hex');
}

export function verifyInbound(
  secret: string,
  timestamp: number,
  payload: string,
  signature: string,
  nowSeconds: number,
): boolean {
  if (!secret || !Number.isFinite(timestamp)) return false;
  if (Math.abs(nowSeconds - timestamp) > INBOUND_MAX_AGE_SECONDS) return false;
  const expected = Buffer.from(signInbound(secret, timestamp, payload), 'hex');
  const given = Buffer.from(/^[0-9a-f]{64}$/i.test(signature) ? signature : '', 'hex');
  return given.length === expected.length && timingSafeEqual(given, expected);
}

/** An email as the Worker forwards it. */
export interface InboundEmail {
  from: { address: string; name?: string | null };
  to: string[];
  subject: string;
  text: string;
  messageId: string | null;
  inReplyTo: string | null;
  references: string[];
  authResults: string[];
  attachments: number;
  /** The Worker saw an auto-reply / bulk / delivery-report marker. */
  automated: boolean;
}

const MAX_BODY = 20000;
const MAX_FULL = 60000;

/** A Message-ID as stored: angle brackets on, whitespace off, bounded. */
export function normalizeMessageId(id: string | null | undefined): string | null {
  const t = (id ?? '').trim();
  if (!t) return null;
  const bare = t.replace(/^<|>$/g, '');
  if (!bare || bare.length > 400 || /\s/.test(bare)) return null;
  return `<${bare}>`;
}

/**
 * Check the Worker's JSON and bound every field. Throws on a shape the Worker
 * never sends (the signature already proved it came from the Worker).
 */
export function parseInbound(json: unknown): InboundEmail {
  const o = (json ?? {}) as Record<string, unknown>;
  const from = (o.from ?? {}) as Record<string, unknown>;
  const address = String(from.address ?? '').trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(address) || address.length > 320) throw new Error('bad from');
  const to = Array.isArray(o.to) ? o.to.map((x) => String(x)).slice(0, 50) : [];
  const strings = (v: unknown, n: number) => (Array.isArray(v) ? v.map((x) => String(x)).slice(0, n) : []);
  return {
    from: { address, name: from.name ? String(from.name).slice(0, 120) : null },
    to,
    subject: String(o.subject ?? '').slice(0, 500),
    text: String(o.text ?? '').slice(0, MAX_FULL),
    messageId: normalizeMessageId(o.messageId as string | null),
    inReplyTo: normalizeMessageId(o.inReplyTo as string | null),
    references: strings(o.references, 50).map(normalizeMessageId).filter((x): x is string => !!x),
    authResults: strings(o.authResults, 10).map((x) => x.slice(0, 2000)),
    attachments: Math.max(0, Math.min(1000, Number(o.attachments) || 0)),
    automated: o.automated === true,
  };
}

/** The message as stored: the new text, and the full text when that differs. */
export function inboundBody(text: string): { body: string; full: string | null } {
  const full = (text ?? '').trim() || '(No text in this email.)';
  const fresh = stripQuotedReply(full);
  return {
    body: fresh.slice(0, MAX_BODY),
    full: fresh === full ? null : full.slice(0, MAX_FULL),
  };
}

/** Days within which a same-sender, same-subject email joins an open thread. */
export const THREAD_WINDOW_DAYS = 14;

export const SUPPORT_FROM = 'Help24 Support <support@help24.co.ke>';
export const SUPPORT_ADDRESS = 'support@help24.co.ke';
const SIGNATURE = 'Help24 Support';

/** Plain text of a staff reply email. */
export function replyText(body: string): string {
  return `${body.trim()}\n\n${SIGNATURE}\nhelp24.co.ke`;
}

const escapeHtml = (s: string) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/**
 * HTML of a staff reply email: the words, the signature, nothing else. Plain
 * and readable in any client; no images, no tracking.
 */
export function replyHtml(body: string): string {
  const paragraphs = body
    .trim()
    .split(/\n{2,}/)
    .map((p) => `<p style="margin:0 0 14px;">${escapeHtml(p).replace(/\n/g, '<br>')}</p>`)
    .join('');
  return (
    '<!doctype html><html lang="en"><body style="margin:0;padding:24px 16px;background:#ffffff;">' +
    '<div style="max-width:560px;font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',Roboto,Helvetica,Arial,sans-serif;font-size:15px;line-height:24px;color:#12161A;">' +
    paragraphs +
    `<p style="margin:24px 0 0;font-weight:600;">${SIGNATURE}</p>` +
    '<p style="margin:2px 0 0;font-size:13px;color:#686F77;"><a href="https://help24.co.ke" style="color:#686F77;">help24.co.ke</a></p>' +
    '</div></body></html>'
  );
}
