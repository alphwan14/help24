// Exchange Firebase ID token for Supabase JWT (so RLS auth.jwt()->>'user_id' works).
// Set secrets: SUPABASE_JWT_SECRET (from Dashboard > API > JWT Secret), FIREBASE_PROJECT_ID (e.g. help24-24410).

import { create, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID") ?? "help24-24410";
const JWT_SECRET = Deno.env.get("SUPABASE_JWT_SECRET");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";

interface FirebaseIdTokenPayload {
  sub: string;
  iss?: string;
  aud?: string;
  exp?: number;
  iat?: number;
}

function decodeJwtPayload(token: string): FirebaseIdTokenPayload | null {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    const payload = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")));
    return payload as FirebaseIdTokenPayload;
  } catch {
    return null;
  }
}

// Verifies Firebase ID token (iss, aud, exp). For production, add signature
// verification using JWKS: https://securetoken.google.com/<project_id>/.well-known/jwks.json
async function verifyFirebaseToken(idToken: string): Promise<string | null> {
  const payload = decodeJwtPayload(idToken);
  if (!payload?.sub) return null;
  const now = Math.floor(Date.now() / 1000);
  if (payload.exp != null && payload.exp < now) return null;
  if (payload.iss !== `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`) return null;
  if (payload.aud !== FIREBASE_PROJECT_ID) return null;
  return payload.sub;
}

function getProjectRef(): string {
  try {
    const m = SUPABASE_URL.match(/https:\/\/([^.]+)/);
    return m ? m[1] : "help24";
  } catch {
    return "help24";
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "Content-Type, Authorization" } });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405, headers: { "Content-Type": "application/json" } });
  }

  let idToken: string | null = null;
  const auth = req.headers.get("Authorization");
  if (auth?.startsWith("Bearer ")) {
    idToken = auth.slice(7);
  } else {
    try {
      const body = await req.json() as { id_token?: string; idToken?: string };
      idToken = body.id_token ?? body.idToken ?? null;
    } catch {
      idToken = null;
    }
  }

  if (!idToken) {
    return new Response(JSON.stringify({ error: "Missing id_token or Authorization: Bearer" }), { status: 400, headers: { "Content-Type": "application/json" } });
  }

  const uid = await verifyFirebaseToken(idToken);
  if (!uid) {
    return new Response(JSON.stringify({ error: "Invalid or expired Firebase token" }), { status: 401, headers: { "Content-Type": "application/json" } });
  }

  if (!JWT_SECRET) {
    return new Response(JSON.stringify({ error: "Server misconfiguration" }), { status: 500, headers: { "Content-Type": "application/json" } });
  }

  const ref = getProjectRef();
  const encoder = new TextEncoder();
  const keyBuf = encoder.encode(JWT_SECRET);
  const key = await crypto.subtle.importKey("raw", keyBuf, { name: "HMAC", hash: "SHA-256" }, true, ["sign"]);

  const expSeconds = 3600;
  const payload = {
    iss: "supabase",
    ref,
    role: "authenticated",
    sub: uid,
    user_id: uid,
    iat: getNumericDate(0),
    exp: getNumericDate(expSeconds),
  };

  const accessToken = await create({ alg: "HS256", typ: "JWT" }, payload, key);

  return new Response(
    JSON.stringify({ access_token: accessToken, refresh_token: accessToken, expires_in: expSeconds }),
    { status: 200, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } }
  );
});
