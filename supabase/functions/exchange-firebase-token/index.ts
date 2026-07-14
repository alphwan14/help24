// Exchange a Firebase ID token for a short-lived Supabase JWT so RLS
// (auth.jwt()->>'user_id') can scope data to the signed-in user.
//
// SECURITY: the Firebase ID token is FULLY verified — RS256 signature against
// Google's rotating public certs (JWKS) PLUS issuer/audience/expiry. Without the
// signature check, anyone could forge a token and impersonate any user once RLS
// relies on this, so it is mandatory before the S3 owner-scoped RLS rollout.
//
// Required secrets:
//   APP_JWT_SECRET       — the project's JWT secret (Dashboard → Project
//                          Settings → API → JWT Secret). NOTE: named
//                          APP_JWT_SECRET because the platform reserves the
//                          SUPABASE_ prefix and rejects custom secrets with it.
//   FIREBASE_PROJECT_ID  — e.g. help24-24410 (defaults below)

import { SignJWT, jwtVerify, importX509, decodeProtectedHeader } from 'https://esm.sh/jose@5.9.6';

const FIREBASE_PROJECT_ID = Deno.env.get('FIREBASE_PROJECT_ID') ?? 'help24-24410';
const JWT_SECRET = Deno.env.get('APP_JWT_SECRET') ?? Deno.env.get('SUPABASE_JWT_SECRET');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
// Google's public x509 certs for Firebase Secure Token (keyed by `kid`).
const CERT_URL = 'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

// Cache the certs per their max-age so we don't fetch on every request.
let certCache: { certs: Record<string, string>; expiresAt: number } | null = null;

async function getGoogleCerts(): Promise<Record<string, string>> {
  const now = Date.now();
  if (certCache && now < certCache.expiresAt) return certCache.certs;
  const res = await fetch(CERT_URL);
  const certs = (await res.json()) as Record<string, string>;
  const maxAge = /max-age=(\d+)/.exec(res.headers.get('cache-control') ?? '')?.[1];
  const ttlMs = maxAge ? parseInt(maxAge, 10) * 1000 : 3_600_000;
  certCache = { certs, expiresAt: now + ttlMs };
  return certs;
}

/** Fully verify a Firebase ID token (RS256 signature + iss/aud/exp).
 *  Returns the uid, or a precise rejection reason (safe to surface: header
 *  shape, key id, or the jose claim-check message — never secrets). */
async function verifyFirebaseToken(
  idToken: string,
): Promise<{ uid: string | null; reason?: string }> {
  try {
    const { kid, alg } = decodeProtectedHeader(idToken);
    if (alg !== 'RS256' || !kid) return { uid: null, reason: 'unexpected token header' };
    const certs = await getGoogleCerts();
    const cert = certs[kid];
    if (!cert) return { uid: null, reason: 'unknown signing key (kid)' };
    const key = await importX509(cert, 'RS256');
    const { payload } = await jwtVerify(idToken, key, {
      issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
      audience: FIREBASE_PROJECT_ID,
    });
    if (typeof payload.sub === 'string' && payload.sub.length > 0) return { uid: payload.sub };
    return { uid: null, reason: 'missing sub claim' };
  } catch (e) {
    return { uid: null, reason: (e as Error)?.message ?? 'verification failed' };
  }
}

function projectRef(): string {
  return /https:\/\/([^.]+)/.exec(SUPABASE_URL)?.[1] ?? 'help24';
}

/** Three dot-separated segments and not a Supabase API key. */
function looksLikeJwt(token: string | null | undefined): token is string {
  return (
    typeof token === 'string' &&
    token.split('.').length === 3 &&
    !token.startsWith('sb_')
  );
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // The BODY is the source of truth for the Firebase token.
  //
  // The Supabase client ALWAYS attaches `Authorization: Bearer <apikey|session>`
  // to functions.invoke — so the header carries the project's publishable key,
  // not a Firebase token. Reading the header first (as this did) meant we tried
  // to verify `sb_publishable_…` as a JWT and every real login failed with
  // "Invalid Token or Protected Header formatting". The header is now only a
  // fallback, and only when it actually carries a JWT-shaped value.
  let idToken: string | null = null;
  try {
    const body = (await req.json()) as { id_token?: string; idToken?: string };
    idToken = body.id_token ?? body.idToken ?? null;
  } catch {
    idToken = null;
  }
  if (!looksLikeJwt(idToken)) {
    const auth = req.headers.get('Authorization');
    const headerToken = auth?.startsWith('Bearer ') ? auth.slice(7) : null;
    idToken = looksLikeJwt(headerToken) ? headerToken : idToken;
  }

  if (!idToken) {
    return new Response(JSON.stringify({ error: 'Missing id_token' }), {
      status: 400,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { uid, reason } = await verifyFirebaseToken(idToken);
  if (!uid) {
    console.error(
      `[EXCHANGE] token rejected: ${reason} (expected project: ${FIREBASE_PROJECT_ID})`,
    );
    return new Response(
      JSON.stringify({ error: 'Invalid or expired Firebase token', reason }),
      { status: 401, headers: { ...CORS, 'Content-Type': 'application/json' } },
    );
  }

  if (!JWT_SECRET) {
    return new Response(JSON.stringify({ error: 'Server misconfiguration: APP_JWT_SECRET not set' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const secret = new TextEncoder().encode(JWT_SECRET);
  const accessToken = await new SignJWT({ role: 'authenticated', user_id: uid, ref: projectRef() })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuer('supabase')
    .setSubject(uid)
    .setIssuedAt()
    .setExpirationTime('1h')
    .sign(secret);

  return new Response(
    JSON.stringify({ access_token: accessToken, refresh_token: accessToken, expires_in: 3600 }),
    { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } },
  );
});
