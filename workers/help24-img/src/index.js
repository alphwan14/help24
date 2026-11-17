// Cloudflare Workers entry point. All behaviour lives in app.js; this file only
// turns the Worker's bindings into the app's dependencies, once per isolate.
//
// Bindings (see wrangler.toml and DEPLOY.md):
//   SUPABASE_URL   var   https://<ref>.supabase.co
//   caches.default       the edge cache of the data centre serving the request
//
// No secrets: the public buckets are read anonymously, and no key is ever sent
// upstream. A missing binding fails CLOSED: every request is refused with 503
// rather than served from somewhere half-configured.

import { createApp } from './app.js';

let app = null;

function build(env) {
  const missing = [];
  if (!env?.SUPABASE_URL) missing.push('SUPABASE_URL');
  const cache = globalThis.caches?.default;
  if (!cache) missing.push('caches.default');
  if (missing.length > 0) {
    // Names only, never values.
    console.error(JSON.stringify({ event: 'config_missing', missing }));
    return null;
  }
  try {
    return createApp({
      supabaseUrl: env.SUPABASE_URL,
      cache,
      // Called through a wrapper: the runtime's fetch must not be detached
      // from the global it belongs to.
      fetch: (input, init) => fetch(input, init),
      log: (event) => console.log(JSON.stringify(event)),
    });
  } catch (e) {
    console.error(JSON.stringify({ event: 'config_invalid', detail: e?.message }));
    return null;
  }
}

export default {
  async fetch(request, env, ctx) {
    app ??= build(env);
    if (!app) {
      return new Response(JSON.stringify({ code: 'UNAVAILABLE' }), {
        status: 503,
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'cache-control': 'no-store',
          'x-content-type-options': 'nosniff',
          'content-security-policy': "default-src 'none'; sandbox",
        },
      });
    }
    return app.fetch(request, ctx);
  },
};
