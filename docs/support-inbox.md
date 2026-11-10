# Support Inbox — members and Help24, both ways

Status: **phase 1 built (2026-11-10), not yet live.** Migration 138 applied
and verified 2026-11-10 (both tables, RLS on, no anon/authenticated access,
refused from outside with the app key). Owner decisions 2026-11-10:
build the Inbox with email first; replies are signed "Help24 Support"; info@
lands in the same Inbox labelled General; keep a copy of every email going to
the team's existing inbox for the first weeks; the new backend work is approved.

## What it is

One place in the dashboard, **Inbox** (under Queues), where every conversation
between a member and Help24 lives, whatever channel it came in on.

| Address | Purpose | Lands in |
|---|---|---|
| `support@help24.co.ke` | Help, problems, account questions; the address the app and website already show | Inbox, **Support** |
| `info@help24.co.ke` | General enquiries | Inbox, **General** |
| `security@help24.co.ke` | Sender of auth emails (Supabase); unchanged | The team inbox, as today |

Members always see **"Help24 Support"**. Which admin wrote a reply is recorded
for the team only. Internal notes are never sent.

## How mail flows

```
member's email
  → Cloudflare Email Routing (support@, info@)
  → Email Worker workers/help24-mail
        ├─ copy to FORWARD_TO (team inbox, safety net)
        └─ POST /support/inbound-email, HMAC-signed
  → backend SupportService → support_conversations / support_messages (138)
  → dashboard Inbox (/dashboard/inbox), alert "support conversations waiting"

staff reply in the Inbox
  → backend → Resend, from "Help24 Support <support@help24.co.ke>",
    subject "Re: <subject> [H24-XXXXXX]", threaded with Message-ID headers
  → member's mailbox; their reply comes back the same way into the same thread
```

**Threading.** A reply finds its conversation by, in order: the `[H24-…]`
reference in its subject from the same sender; the In-Reply-To/References
headers against messages we hold, from the same sender; or the same sender's
open thread on the same subject within 14 days. Otherwise it starts a new one.

**Safety.**
- The inbound endpoint is public only at the door; every request must carry the
  Worker's HMAC signature (five-minute window). Mis-signed requests get 401.
- An email's From line can be forged. The Inbox shows "Sender not verified"
  when the receiving server's SPF/DKIM/DMARC verdict did not vouch for it, and
  linking an address to a member is for display only: nothing is granted
  because of it. The Inbox reminds staff to confirm identity before changing
  an account.
- Auto-replies, bounces, mailing lists and mail from our own domain are never
  stored, so replies cannot loop.
- The same email delivered twice is stored once (unique Message-ID).
- A reply that cannot be sent is kept, marked **Not sent** with the reason, and
  sent again with **Try again** (same idempotency key: never delivered twice).
- Nothing is lost silently: if the backend cannot take an email and no copy
  went to the team inbox, the Worker refuses it, so the sender is told.

## What exists after phase 1

| Piece | Where |
|---|---|
| Tables, RLS (service role only) | `supabase/migrations/138_support_inbox.sql` |
| Rules (threading, quoting, signature, reply email) | `backend/src/support/support-rules.ts` |
| Inbox service, mailer (Resend), controllers | `backend/src/support/` |
| Alert `support_waiting` (gives the Inbox its nav badge) | `backend/src/admin/alerts/` |
| Email Worker | `workers/help24-mail/` (see its DEPLOY.md) |
| Dashboard Inbox, conversation, New message | `admin-dashboard/app/dashboard/inbox/` |
| Member page **Email** button | now opens New message (sent as Help24 Support), not the admin's own mail app |

Tests: backend `src/support/*.spec.ts` (27), Worker `test/mail.test.js` (7),
dashboard e2e section "support inbox" (11 checks).

## Rollout (owner steps, in order)

1. **Apply migration 138.** Done 2026-11-10.
2. **Render** (help24-backend → Environment): `RESEND_API_KEY` (a Resend API
   key with sending access for help24.co.ke; already set, checked by name
   2026-11-10) and `SUPPORT_INBOUND_SECRET` (the PowerShell line in the
   Worker's DEPLOY.md, or `openssl rand -hex 32`). Then the backend is merged
   to main and deploys.
3. **Worker:** `workers/help24-mail/DEPLOY.md` — deploy, then set
   `SUPPORT_INBOUND_SECRET` (same value) and `FORWARD_TO` (the team inbox,
   already a verified Email Routing destination).
4. **Email Routing:** support@ and info@ → Send to a Worker → help24-mail.
5. **DMARC** (Cloudflare DNS, TXT, name `_dmarc`): `v=DMARC1; p=none`.
   Resend already signs as help24.co.ke (DKIM) and sends through
   `send.help24.co.ke` (SPF), so DMARC passes; the record tells Gmail and Yahoo
   what to do with mail that fails. Tighten to `p=quarantine` after a few clean
   weeks. No `rua` for now: reports would arrive in the Inbox.
6. **Dashboard** deploy.
7. **Check:** email support@ from a personal address, see it in the Inbox,
   reply, reply to the reply.

## Next phases (not built)

2. **In the app:** Profile → Support → "Message Help24" opens the member's
   conversation; staff replies arrive as in-app notifications and pushes. Same
   tables (`channel = 'app'`), plus a member read policy on their own
   non-internal messages. Needs an app release (or a patch without new
   translation strings).
3. **Broadcasts:** announcements to an audience (everyone, providers,
   clients, a city, chosen people) by in-app + push, and by email from
   `Help24 <info@help24.co.ke>` with one-click unsubscribe (announcements only).
   Reach shown before sending, a test to yourself, senior and super admins
   only. The App controls announcement banner stays as it is.
4. **Later, with traffic:** SMS (Africa's Talking) and WhatsApp Business for
   urgent messages, saved replies, assigning conversations, response-time
   targets, keeping attachments in the Inbox.
