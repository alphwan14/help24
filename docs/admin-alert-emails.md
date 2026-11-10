# Email alerts for admins

Status: built 2026-11-11. Needs migration 141. Owner decisions: send from
"Help24 Admin" <alerts@help24.co.ke>; right away by default; each admin
chooses for themselves.

## What it does

Admins had no way to know something needed them without signing in. The
backend now checks the console's alert list (the same one behind the sidebar
counts, `backend/src/admin/alerts`) every five minutes and emails each admin
about what is **new**:

- an alert that just appeared;
- a newer record joining an alert (a member wrote again, a new report);
- more records joining an alert.

Never again just because something is still waiting. Reviewed alerts are
silent. Low-priority marketplace health is left for the morning summary.

Each admin sets their own choice in **Settings → Email alerts**:

| How often | What happens |
|---|---|
| Right away (default) | Within about five minutes of something new |
| Morning summary | One email from 08:00 Nairobi with everything still waiting |
| Off | Nothing |

About: Support Inbox · Money (payments, payouts, disputes) · Trust & safety
(reports, verifications, admin logins) · Marketplace (jobs, requests,
promotions). "Send me a test" mails a sample to the admin's own address.

## What an email may say

The kind of alert, how many, and a link into `https://admin.help24.co.ke`.
Never member names, message text, phone numbers or amounts: emails get
forwarded and phones get lost. Tests in `alert-email-rules.spec.ts` plant a
member's name, phone and amount in an alert and check none of it reaches the
email. Links always use the console's own domain, never a hosting address.

## Pieces

| Piece | Where |
|---|---|
| Tables (settings per admin; what was last announced) | `supabase/migrations/141_admin_alert_emails.sql` |
| Rules (what is new, morning timing, the email) | `backend/src/admin/alert-emails/alert-email-rules.ts` |
| Sweep, settings, test email | `backend/src/admin/alert-emails/admin-alert-emails.service.ts` |
| API: `GET/PUT /admin/alert-emails`, `POST /admin/alert-emails/test` | same folder, the admin behind the token only |
| Settings card | `admin-dashboard/app/dashboard/settings/AlertEmailsForm.tsx` |

Sends through the same Resend key as the Inbox (`RESEND_API_KEY`). Without
the key or before migration 141 it does nothing, quietly.
`ADMIN_ALERT_EMAILS=off` on Render stops it entirely.

## Limits

- The backend runs on Render's free plan and stays awake only because the
  uptime pinger calls it. If it sleeps, alerts arrive late, never lost.
- alerts@ takes no replies (no routing rule); every email says so.
- Later: browser push notifications for the console.
