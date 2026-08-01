/**
 * Secret and PII scrubbing for log output.
 *
 * THE PROBLEM THIS SOLVES
 * -----------------------
 * "Do not log secrets" is easy to state and impossible to enforce by review
 * alone, because the leaks are never in the line someone wrote deliberately —
 * they are in `JSON.stringify(body)` on a callback handler, or in an error
 * message that happens to echo a request. This module makes the guarantee
 * structural: every message and every metadata object goes through it on the
 * way out, so a secret has to survive an explicit filter to reach a log file.
 *
 * TWO MECHANISMS, BECAUSE THERE ARE TWO SHAPES OF LOG
 * --------------------------------------------------
 *   redactObject()  keys are known → match on the KEY NAME. Precise, cheap,
 *                   and it does not care what the value looks like.
 *   redactText()    the log is already a string (`JSON.stringify(body)` in the
 *                   M-Pesa callback handlers, for instance) → match on the
 *                   VALUE SHAPE. Necessarily heuristic, so it targets the
 *                   handful of shapes that actually appear in this system.
 *
 * WHY PHONE NUMBERS ARE INCLUDED
 * ------------------------------
 * An MSISDN is not a secret, but it is the primary identifier of a real person
 * in this market and it appears in every M-Pesa payload the callback handlers
 * already log verbatim. Masking the middle digits keeps the number recognisable
 * for debugging ("is this the same payer?") while a leaked log file no longer
 * hands anyone a list of customer phone numbers. Set LOG_MASK_PII=false to
 * disable when investigating a specific payment locally.
 */

/**
 * Key names whose VALUES are never safe to log, matched case-insensitively as
 * substrings so `MPESA_CONSUMER_SECRET`, `consumerSecret` and `secret` are all
 * caught by one entry.
 *
 * Substring matching over-matches by design: a false positive costs one masked
 * debugging field, a false negative costs a credential.
 */
const SENSITIVE_KEY_FRAGMENTS = [
  'password',
  'passwd',
  'secret',
  'token',
  'authorization',
  'auth',
  'apikey',
  'api_key',
  'credential',
  'passkey',
  'privatekey',
  'private_key',
  'clientsecret',
  'client_secret',
  'servicerole',
  'service_role',
  'otp',
  'pin',
  'securitycredential',
  'cookie',
  'session',
  'signature',
];

const MASK = '[REDACTED]';

/** Depth ceiling — a cyclic or pathologically deep object must not hang a log call. */
const MAX_DEPTH = 6;
/** Array ceiling — logging 10,000 elements is never the intent. */
const MAX_ARRAY_ITEMS = 50;

function isSensitiveKey(key: string): boolean {
  const normalized = key.toLowerCase().replace(/[-_\s]/g, '');
  return SENSITIVE_KEY_FRAGMENTS.some((fragment) =>
    normalized.includes(fragment.replace(/[-_]/g, '')),
  );
}

/**
 * Deep-copy `value`, replacing sensitive values with a mask.
 *
 * Never throws and never returns the original object: callers can hand it a
 * request body without worrying that a getter will fire or that a later
 * mutation will change what was logged.
 */
export function redactObject(value: unknown, depth = 0): unknown {
  if (value === null || value === undefined) return value;
  if (depth > MAX_DEPTH) return '[truncated: max depth]';

  if (typeof value === 'string') return redactText(value);
  if (typeof value === 'number' || typeof value === 'boolean') return value;
  if (typeof value === 'bigint') return value.toString();
  if (typeof value === 'function') return '[function]';
  if (value instanceof Date) return value.toISOString();
  if (value instanceof Error) {
    return { name: value.name, message: redactText(value.message), stack: value.stack };
  }

  if (Array.isArray(value)) {
    const items = value.slice(0, MAX_ARRAY_ITEMS).map((item) => redactObject(item, depth + 1));
    if (value.length > MAX_ARRAY_ITEMS) {
      items.push(`[truncated: ${value.length - MAX_ARRAY_ITEMS} more items]`);
    }
    return items;
  }

  if (typeof value === 'object') {
    const source = value as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(source)) {
      out[key] = isSensitiveKey(key) ? MASK : redactObject(source[key], depth + 1);
    }
    return out;
  }

  return String(value);
}

// ── Value-shape patterns, applied to free text ───────────────────────────────

/** `Authorization: Bearer <anything>` in any casing. */
const BEARER = /\b(bearer\s+)[A-Za-z0-9._~+/=-]{8,}/gi;

/**
 * A JWT: three base64url segments. Supabase access tokens, Firebase ID tokens
 * and the admin session tokens all match, so this one pattern covers every
 * credential the app actually carries.
 */
const JWT = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g;

/**
 * `"password": "…"` inside an already-serialised JSON string — the case
 * redactObject cannot reach because the object became text before it got here.
 */
const JSON_SENSITIVE_FIELD = new RegExp(
  `("(?:[^"]*(?:${SENSITIVE_KEY_FRAGMENTS.join('|')})[^"]*)"\\s*:\\s*)"[^"]*"`,
  'gi',
);

/**
 * Kenyan MSISDNs in both forms the platform normalises between.
 *
 * The lookarounds exclude digits embedded in a longer token — without them the
 * final 12-digit segment of a UUID could be mistaken for a 254-prefixed number
 * and mangled, making IDs harder to trace for no security gain.
 */
const MSISDN_254 = /(?<![\w-])254\d{9}(?![\w-])/g;
const MSISDN_0X = /(?<![\w-])0[17]\d{8}(?![\w-])/g;

function maskPhone(match: string): string {
  return `${match.slice(0, 3)}${'*'.repeat(match.length - 6)}${match.slice(-3)}`;
}

function piiMaskingEnabled(): boolean {
  return process.env.LOG_MASK_PII?.trim().toLowerCase() !== 'false';
}

/**
 * Scrub credential- and PII-shaped substrings from free text.
 *
 * Order matters: JSON field masking runs before the phone patterns so a
 * `"phone":"254…"` pair is handled as a field rather than half-masked as a
 * bare number.
 */
export function redactText(text: string): string {
  if (!text) return text;

  let out = text
    .replace(BEARER, '$1[REDACTED]')
    .replace(JWT, '[REDACTED_JWT]')
    .replace(JSON_SENSITIVE_FIELD, `$1"${MASK}"`);

  if (piiMaskingEnabled()) {
    out = out.replace(MSISDN_254, maskPhone).replace(MSISDN_0X, maskPhone);
  }

  return out;
}
