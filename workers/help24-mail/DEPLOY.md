# help24-mail — deploying support@ and info@ into the Inbox

The Cloudflare Email Worker behind the dashboard's support Inbox. Design:
[docs/support-inbox.md](../../docs/support-inbox.md).

Every step below changes production, so each needs explicit approval first.
Commands run from `workers/help24-mail/`. Wrangler is logged in with OAuth
(`npx wrangler whoami`).

## 0. Before anything

```sh
npm install                      # postal-mime, pinned
node --test "test/*.test.js"     # parsing, signing, retries, the handler
npx wrangler deploy --dry-run    # bundles, uploads nothing
```

Order of the whole rollout:

1. Migration `supabase/migrations/138_support_inbox.sql` applied.
2. Backend deployed (push to main) with `SUPPORT_INBOUND_SECRET` and
   `RESEND_API_KEY` set on Render.
3. This Worker deployed, with its two secrets (below).
4. Email Routing rules pointed at it (below). Only now does mail reach the Inbox.

## 1. Deploy

```sh
npx wrangler deploy
```

No route or domain: an Email Worker is invoked by Email Routing only.

## 2. Secrets — piped, never typed into a command line

```sh
# The same value as SUPPORT_INBOUND_SECRET on Render (openssl rand -hex 32).
<paste> | npx wrangler secret put SUPPORT_INBOUND_SECRET
# The team inbox that receives a copy of every email. It must already be a
# VERIFIED destination address under Email Routing → Destination addresses.
<paste> | npx wrangler secret put FORWARD_TO
```

Until SUPPORT_INBOUND_SECRET is set, the Worker forwards the copy (if
FORWARD_TO is set) and otherwise refuses the email, so the sender is told.

## 3. Email Routing

Cloudflare → help24.co.ke → Email → Email Routing → Routing rules:

| Custom address | Action |
|---|---|
| `support@help24.co.ke` | Send to a Worker → `help24-mail` |
| `info@help24.co.ke` | Send to a Worker → `help24-mail` |

Leave `security@` as it is (it forwards to the team inbox). The Worker files
info@ under **General** and everything else under **Support**.

## 4. Check

Send an email from a personal address to support@help24.co.ke. Within a
minute it is in the dashboard's Inbox under Needs reply, and the copy is in
the FORWARD_TO inbox. Reply from the Inbox; the answer arrives from
"Help24 Support <support@help24.co.ke>" with `[H24-…]` in the subject.
Reply to that, and it joins the same conversation.

## Rollback

Point the two routing rules back at "Send to an email" (the team inbox).
Nothing else depends on the Worker.
