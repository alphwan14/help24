# help24-img — deploying img.help24.co.ke

The Worker that serves the app's public photos (post photos, their thumbnails,
avatars) from Supabase Storage through Cloudflare's edge cache. The app
rewrites `https://<ref>.supabase.co/storage/v1/object/public/<bucket>/<path>`
to `https://img.help24.co.ke/<bucket>/<path>` at display time.

Every step below changes production, so each needs explicit approval first.
Commands run from `workers/help24-img/`. Wrangler is logged in with OAuth
(`npx wrangler whoami`); no API token is needed. The Worker has no secrets.

**Check the account first.** `whoami` must show the account that owns the
`help24.co.ke` zone (alphwan14's, where help24-files and help24-mail live).
On 2026-11-17 this PC was logged in to someone else's account: the deploy
uploaded the script there and then failed on the domain ("zone does not
exist on your account"). After switching the login, wrangler still aimed at
the old account from `.wrangler/cache/wrangler-account.json` in this folder;
deleting that file fixed it.

Live since 2026-11-17 (version `d4e81564`).

## 0. Before anything

```sh
node --test "test/*.test.js"     # unit + security suite (31 tests)
npx wrangler deploy --dry-run    # bundles, uploads nothing
```

## 1. Deploy

```sh
npx wrangler deploy
```

This creates the Worker and the Custom Domain `img.help24.co.ke` (Cloudflare
creates the DNS record and the certificate; the hostname must not already have
a DNS record — it had none on 2026-11-16). `workers_dev` and preview URLs are
off, so this hostname is the only way in.

## 2. Verify

Use any real post photo path, `post-images/posts/<uuid>.jpg`.

```sh
P=post-images/posts/<uuid>.jpg
curl -s -o /dev/null -D - https://img.help24.co.ke/$P | grep -iE '^(HTTP|cf-cache-status|content-type|cache-control)'
#   200, cf-cache-status: MISS, image/jpeg, public, max-age=31536000, immutable
curl -s -o /dev/null -D - https://img.help24.co.ke/$P | grep -i cf-cache-status
#   HIT (from the same data centre)
curl -si https://img.help24.co.ke/chat-attachments/00000000-0000-4000-8000-000000000000/x.jpg | head -1   # 404
curl -si https://img.help24.co.ke/post-images/test/x.jpg | head -1                                       # 404
curl -si -X POST https://img.help24.co.ke/$P | head -1                                                   # 405
```

Only then turn on the app's App controls switch "Photos through Cloudflare".

## Logs

`observability` is off on purpose: invocation logs record request URLs, and an
avatar's URL carries its owner's uid. `npx wrangler tail` shows the Worker's own
lines (an event name, a status and a bucket, never a uid or a path), but tail
also prints each request's URL, so do not paste tail output anywhere.

## Limits worth knowing

- Workers Free: 100,000 requests a day, and a cache HIT still counts as one.
  Every photo a phone shows is one request until its own image cache has it.
- The Cache API is per data centre (no tiered cache): the first view in each
  Cloudflare location is a MISS that goes to Supabase, and the edge may evict
  any entry early.
- Avatars are revalidated with Supabase once their edge copy is 5 minutes old;
  while Supabase is failing, a copy up to a day old is served as STALE.
- A missing post photo or thumbnail is remembered as a 404 for 10 minutes, so
  a thumbnail a backfill adds afterwards appears within that window.

## Rollback

Turn off "Photos through Cloudflare" in App controls first: the app goes back
to direct Supabase URLs without a release. Then, if the Worker itself must go:

```sh
npx wrangler delete help24-img     # removes the Worker and its custom domain
```
