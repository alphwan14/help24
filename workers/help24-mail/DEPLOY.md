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

## 2. Secrets

Set on the Worker, never written in this repo. Spaces or a newline around a
pasted value are ignored, by the Worker and by the backend alike.

**Cloudflare dashboard** (simplest): Workers & Pages → `help24-mail` →
Settings → Variables and Secrets → Add, type **Secret**, then Deploy.

| Name | Value |
|---|---|
| `SUPPORT_INBOUND_SECRET` | the same value as on Render (help24-backend → Environment); make one with the PowerShell line below |
| `FORWARD_TO` | the team inbox(es) that get a copy of every email, comma-separated (up to 5). Each must already be a **verified** address under Email Routing → Destination addresses; an unverified one is skipped, the others still get their copy |

To make the secret on Windows without it ever being shown (it lands on the
clipboard, ready to paste into Render):

```powershell
$b = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b | ForEach-Object { $_.ToString('x2') }) | Set-Clipboard
```

**Or from a terminal**, piped so the value never sits in shell history:

```sh
# The same value as SUPPORT_INBOUND_SECRET on Render (openssl rand -hex 32).
<paste> | npx wrangler secret put SUPPORT_INBOUND_SECRET
# The team inbox that receives a copy of every email (verified destination).
<paste> | npx wrangler secret put FORWARD_TO
```

If the secret ever leaks, make a new one and replace it in both places
(Render first, then here); mail arriving in between still reaches the team
inbox through the copy.

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
