# help24-files — deploying files.help24.co.ke

The Worker that guards private chat attachments. Design and rollout:
[docs/private-chat-attachments.md](../../docs/private-chat-attachments.md).

Every step below changes production, so each needs explicit approval first.
Commands run from `workers/help24-files/`. Wrangler is logged in with OAuth
(`npx wrangler whoami`); no API token is needed.

## 0. Before anything

```sh
node --test "test/*.test.js"                          # unit + security suite (76 tests)
node scripts/live-security-test.mjs --identity local  # read-only, against live data
npx wrangler deploy --dry-run                         # bundles, uploads nothing
```

Migration `supabase/migrations/118_private_chat_attachments.sql` (the private
bucket) must be applied first — uploads fail until it exists.

## 1. Deploy

```sh
npx wrangler deploy
```

This creates the Worker, its `LinkNonce` Durable Object class (SQLite-backed —
the kind the Workers Free plan allows), the two rate-limit bindings and the
Custom Domain `files.help24.co.ke` (Cloudflare creates the DNS record and the
certificate; the hostname must not already have a DNS record — it had none on
2026-10-04). `workers_dev` and preview URLs are off, so this hostname is the
only way in.

Until step 2 the Worker answers every request with 503: it refuses to run
with a missing secret.

## 2. Secrets — piped, never typed or echoed

```sh
# The server key. Prefer a DEDICATED secret key created for this Worker in
# Supabase → Project Settings → API Keys (revocable on its own). Otherwise the
# backend's key, read straight from backend/.env:
node -e "const e=require('../../backend/node_modules/dotenv').parse(require('fs').readFileSync('../../backend/.env'));process.stdout.write(e.SUPABASE_SERVICE_ROLE_KEY)" \
  | npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY

# 32 random bytes that sign links, cookies and member tags. Rotating it
# invalidates every outstanding link and cookie (they last minutes) — nothing else.
node -e "process.stdout.write(require('crypto').randomBytes(32).toString('base64url'))" \
  | npx wrangler secret put LINK_SIGNING_SECRET
```

## 3. Verify

```sh
curl -si https://files.help24.co.ke/d/00000000-0000-4000-8000-000000000000 | head -1   # 401
curl -si https://files.help24.co.ke/ | head -1                                          # 404
curl -si https://files.help24.co.ke/storage/v1/object/list/post-images | head -1        # 404
# Real Firebase tokens (signs in the two test accounts and a probe uid — approval needed):
node scripts/live-security-test.mjs --identity firebase --base https://files.help24.co.ke
```

## Logs

`observability` is off on purpose (invocation logs would record request URLs,
and a one-time link carries its token in the URL for the one request that
burns it). For live debugging, `npx wrangler tail` shows the Worker's own lines
(never a token, a uid or a full id) — but tail also prints each request's URL,
so a link exchange shows its `?t=` token. That token is already burnt and
expires two minutes after it was minted; still, do not paste tail output
anywhere.

## Limits worth knowing

- One-time links are burnt in a Durable Object per link: strongly consistent,
  so of any number of simultaneous uses exactly one succeeds (checked in local
  workerd: 10 concurrent burns → 1 accepted). Free plan: 100,000 Durable Object
  requests a day — one per document opened in a browser.
- Per-user rate limits (wrangler.toml): 20 uploads and 20 browser links a
  minute; above that the Worker answers 429 and the app's outbox retries.
- Uploads whose message row never arrives stay in the bucket. There is
  deliberately no automatic sweeper: a photo uploaded just before the phone
  went offline is written to its message only on reconnect, possibly days
  later, and a sweeper could delete it first.

## Rollback

```sh
npx wrangler delete help24-files     # removes the Worker and its custom domain
```

The app then cannot load chat photos or documents (they are private), so roll
back only together with a fix, never as a way to "go back to public".
