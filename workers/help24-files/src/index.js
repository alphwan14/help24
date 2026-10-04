// Cloudflare Workers entry point. All behaviour lives in app.js; this file only
// turns the Worker's bindings into the app's dependencies, once per isolate.
//
// Bindings (see wrangler.toml and DEPLOY.md):
//   SUPABASE_URL               var     https://<ref>.supabase.co
//   FIREBASE_PROJECT_ID        var     the Firebase project whose ID tokens are accepted
//   SUPABASE_SERVICE_ROLE_KEY  secret  server key; never leaves this Worker
//   LINK_SIGNING_SECRET        secret  ≥ 32 random chars; signs links, cookies and member tags
//   LINK_NONCES                Durable Object namespace (LinkNonce) — burnt one-time links
//   UPLOAD_LIMITER             rate limit binding (optional) — uploads per user
//   LINK_LIMITER               rate limit binding (optional) — browser links per user
//
// A missing required binding fails CLOSED: every request is refused with 503
// rather than served with a half-configured check.

import { createApp } from './app.js';
import { createFirebaseVerifier } from './firebase-auth.js';
import { LinkNonce, durableNonces } from './nonce-store.js';
import { createSupabase } from './supabase.js';

export { LinkNonce };

const REQUIRED = ['SUPABASE_URL', 'FIREBASE_PROJECT_ID', 'SUPABASE_SERVICE_ROLE_KEY', 'LINK_SIGNING_SECRET', 'LINK_NONCES'];

let app = null;

function build(env) {
  const missing = REQUIRED.filter((name) => !env[name]);
  if (missing.length > 0) {
    // Names only — never values.
    console.error(JSON.stringify({ event: 'config_missing', missing }));
    return null;
  }
  try {
    return createApp({
      verifyIdToken: createFirebaseVerifier({ projectId: env.FIREBASE_PROJECT_ID }),
      supabase: createSupabase({ url: env.SUPABASE_URL, serviceKey: env.SUPABASE_SERVICE_ROLE_KEY }),
      nonces: durableNonces(env.LINK_NONCES),
      signingSecret: env.LINK_SIGNING_SECRET,
      limits: { upload: env.UPLOAD_LIMITER, link: env.LINK_LIMITER },
      log: (event) => console.log(JSON.stringify(event)),
    });
  } catch (e) {
    console.error(JSON.stringify({ event: 'config_invalid', detail: e?.message }));
    return null;
  }
}

export default {
  async fetch(request, env) {
    app ??= build(env);
    if (!app) {
      return new Response(JSON.stringify({ code: 'UNAVAILABLE' }), {
        status: 503,
        headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
      });
    }
    return app.fetch(request);
  },
};
