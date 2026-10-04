// Run the Worker's app on this machine with the REAL dependencies: Google's
// Firebase keys, the production Supabase project (service key from
// backend/.env, held in memory only) and an in-memory nonce store.
//
//   node scripts/serve-local.mjs [--port 8787] [--host 127.0.0.1]
//
// This is the same createApp() the Worker runs; only the HTTP shell and the KV
// store differ. It makes no writes unless a client PUTs an upload, and the
// private bucket must exist for that.
//
// Logged per request: method, path WITHOUT its query string, status. Never a
// token, header or body.

import { createServer } from 'node:http';
import { Readable } from 'node:stream';
import { randomBytes } from 'node:crypto';
import { createApp } from '../src/app.js';
import { createFirebaseVerifier } from '../src/firebase-auth.js';
import { createSupabase } from '../src/supabase.js';
import { loadBackendEnv, need } from './lib/env.mjs';

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : fallback;
};
const port = Number(arg('port', process.env.PORT ?? 8787));
const host = arg('host', '127.0.0.1');

const env = loadBackendEnv();
need(env, 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'FIREBASE_PROJECT_ID');

/** In-memory stand-in for the LinkNonce Durable Object (one process = one store). */
function memoryNonces() {
  const used = new Set();
  return {
    async burn(nonce) {
      if (used.has(nonce)) return false;
      used.add(nonce);
      return true;
    },
  };
}

const app = createApp({
  verifyIdToken: createFirebaseVerifier({ projectId: env.FIREBASE_PROJECT_ID }),
  supabase: createSupabase({ url: env.SUPABASE_URL, serviceKey: env.SUPABASE_SERVICE_ROLE_KEY }),
  nonces: memoryNonces(),
  // Fresh per run: links and cookies from a previous run stop working.
  signingSecret: randomBytes(32).toString('base64url'),
  log: (e) => {
    if (e.event !== 'request') console.log(`  · ${JSON.stringify(e)}`);
  },
});

const server = createServer(async (req, res) => {
  const url = `http://${req.headers.host ?? `${host}:${port}`}${req.url}`;
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) {
    if (Array.isArray(v)) v.forEach((x) => headers.append(k, x));
    else if (v !== undefined) headers.set(k, v);
  }
  const hasBody = req.method !== 'GET' && req.method !== 'HEAD';
  const request = new Request(url, {
    method: req.method,
    headers,
    body: hasBody ? Readable.toWeb(req) : undefined,
    duplex: hasBody ? 'half' : undefined,
  });
  let response;
  try {
    response = await app.fetch(request);
  } catch (e) {
    response = new Response('{"code":"UNAVAILABLE"}', { status: 503 });
  }
  const out = {};
  for (const [k, v] of response.headers) if (k !== 'set-cookie') out[k] = v;
  const cookies = response.headers.getSetCookie();
  if (cookies.length) out['set-cookie'] = cookies;
  res.writeHead(response.status, out);
  if (response.body && req.method !== 'HEAD') {
    Readable.fromWeb(response.body).pipe(res);
  } else {
    res.end();
  }
  console.log(`${new Date().toISOString()} ${req.method} ${new URL(url).pathname} → ${response.status}`);
});

server.listen(port, host, () => {
  console.log(`help24-files (local) on http://${host}:${port} — Supabase ${new URL(env.SUPABASE_URL).host}, Firebase ${env.FIREBASE_PROJECT_ID}`);
});
