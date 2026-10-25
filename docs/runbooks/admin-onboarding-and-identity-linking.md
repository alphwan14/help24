# Runbook — admin onboarding and identity linking

Applies from migration **099** onward (applied to production 2026-08-06).

## The model this enforces

> One person = one `public.users` row, keyed by their **Firebase UID**.
> A Supabase Auth account is a **credential for the admin dashboard**. It is
> linked to a Help24 identity in `user_auth_identities`. It is never a person.

Before 099, `on_auth_user_created` mirrored every new `auth.users` row into
`public.users`, so creating a dashboard login created a marketplace member. That
trigger is gone. Nothing creates a Help24 identity except using the app.

---

## 1. Onboarding a new admin

**Prerequisite: the person must already have a Help24 account**, i.e. they have
signed into the mobile app at least once. There is no longer any way for the
dashboard to create one, and that is deliberate.

1. Confirm they exist and note their Help24 id:

   ```sql
   select id, email, role, created_at from public.users
   where lower(email) = lower('<their-email>');
   ```

   No row → stop. Ask them to sign into the app first.

2. Create their dashboard credential (Supabase Auth account) — the dashboard's
   **Admin Roles → Invite an admin**, or Supabase Studio → Authentication →
   **Add user** (with a password). Note the resulting `auth.users.id`. Do not use
   Studio's **Invite user**: its link signs the person in without ever asking
   for a password, and nothing in the dashboard handles that landing.

   When they accept a dashboard invite, they choose their password and — until
   step 3 is done — are signed straight back out and told a super admin still
   has to finish activating the account (`/login?message=invite-pending`).
   After step 3 they sign in with that password. A re-invited admin whose
   credential is already linked goes straight to the dashboard.

3. Link the credential to the person. **This is the step that grants nothing on
   its own** — it only says which person the credential belongs to:

   ```sql
   insert into public.user_auth_identities (help24_user_id, provider, subject, linked_by)
   values ('<firebase-uid>', 'supabase', '<auth-users-id>', '<your-email>');
   ```

4. Promote them. Use the dashboard's **Make Admin** button (the `updateUserRole`
   server action, service_role, server-side checked). Direct SQL is a fallback,
   not the path.

5. Verify — they should show both identities and `role = 'admin'`:

   ```sql
   select u.email, u.role,
          string_agg(i.provider || ':' || i.subject, ' | ' order by i.provider) as identities
   from public.users u
   join public.user_auth_identities i on i.help24_user_id = u.id
   where lower(u.email) = lower('<their-email>')
   group by u.email, u.role;
   ```

**If you skip step 3**, the dashboard denies them. That is correct behaviour, not
a bug: `middleware.ts` resolves admins through `user_auth_identities`, never by
email. Failing closed is the point.

---

## 2. Removing an admin

Demote via the dashboard (**Remove Admin**). To also revoke dashboard access
entirely, delete the credential link — the person and all their marketplace data
are untouched:

```sql
delete from public.user_auth_identities
where provider = 'supabase' and subject = '<auth-users-id>';
```

Deleting the `auth.users` row as well is optional and independent.

---

## 3. Adjudicating a link candidate

`identity.auth_link_candidates` lists Supabase Auth accounts whose **email
matches a different Help24 identity** — i.e. someone holds both a dashboard
credential and an app account, and nothing has yet said they are the same person.

```sql
select * from identity.auth_link_candidates;
```

This view is intentionally not automated away. An email match is evidence, not
proof, and linking the wrong pair hands one person another person's identity.

For each row, before linking, confirm **out of band** (ask them) that the two
accounts are the same human. Then:

```sql
insert into public.user_auth_identities (help24_user_id, provider, subject, linked_by)
values ('<candidate_help24_user_id>', 'supabase', '<auth_subject>', '<your-email>');
```

Always set `linked_by`. A `NULL` there means "mechanical backfill from data that
was already unambiguous"; a name there means a human made a judgement call and
owns it.

Reversal is one `delete` on the same primary key.

> Adjudicated on 2026-08-06 by alphwan14@gmail.com: `alphwan14@gmail.com` and
> `alphlincoln18@gmail.com` — both dashboard credentials linked to their existing
> Firebase identities. The view is now empty.

---

## 4. The three dashboard-mirror rows — leave them alone

`christianobuna3@gmail.com`, `zurinsojars@gmail.com`, `karenbrina98@gmail.com`
are UUID-keyed `public.users` rows created by the old trigger. Verified
2026-08-06: they own **0** posts, applications, messages, chats and reviews.

Do not delete them and do not merge them. They are inert, and deletion is not
reversible.

The one case that forces a decision: such a person later signs into the **mobile
app** with the same email. Firebase mints a new UID, the app tries to insert a
second `public.users` row, and `users_email_unique` rejects it. Handle it
deliberately:

1. Do not delete the mirror row to "make room" — that silently discards a
   dashboard identity.
2. Decide which row is the person. If the mirror row owns nothing (check with the
   query in §5), the Firebase row is the person.
3. Free the email on the mirror row rather than destroying it, then let the app
   create the Firebase row, then link the old credential to the new identity:

   ```sql
   begin;
   update public.users
      set email = '<old-email>+retired-mirror@help24.invalid'
    where id = '<mirror-uuid>';
   -- have them complete app sign-in now, then:
   insert into public.user_auth_identities (help24_user_id, provider, subject, linked_by)
   values ('<new-firebase-uid>', 'supabase', '<mirror-uuid>', '<your-email>');
   commit;
   ```

   `public.users.email` is guarded by migration 098, so this must be run as
   `service_role` or from the SQL editor. That is intentional friction.

4. Record what you did and why, here.

---

## 5. Is a row safe to touch?

```sql
select u.id, u.email, u.role,
  (select count(*) from public.posts p where p.author_user_id = u.id)      as posts,
  (select count(*) from public.applications a where a.applicant_user_id = u.id) as applications,
  (select count(*) from public.chat_messages m where m.sender_id = u.id)   as messages,
  (select count(*) from public.chats c where c.user1 = u.id or c.user2 = u.id) as chats,
  (select count(*) from public.reviews r where r.provider_id = u.id or r.client_id = u.id) as reviews
from public.users u where u.id = '<id>';
```

All zeros means the row is inert. Any non-zero means a merge would move real
data, and that needs a written plan, not a runbook step.

---

## 6. Known gap

`ojarszurins1992@inbox.lv` holds `role = 'admin'` on a Firebase-keyed row but has
**no Supabase Auth credential at all**, so they cannot sign into the dashboard.
This was equally true before 099 — the email gate had nothing to match either.
Either onboard them properly (§1 steps 2–3) or demote them, so the admin list
reflects who can actually act.

> **Adjudicated 2026-10-25 by the project owner.** This person's dashboard
> credential is one of the §4 mirror addresses (its mirror row no longer
> exists). The owner confirmed out of band that both are one person, and the logs
> agree (app and dashboard backend last used six minutes apart on 2026-07-30).
> Linked with the §3 insert, `linked_by` set. Middleware now resolves the
> credential to the admin row.
>
> **Still blocked after linking:** the backend's `restoreSession` gates on
> `public.users.role` **by session email**, and the dashboard credential's email
> has no `public.users` row — so the shell lands on "Your session needs
> refreshing". Linking is necessary but not sufficient while the backend gate is
> email-based. Any admin whose dashboard email differs from their app email hits
> the same wall.
>
> Same day: an invitation issued for another person was accepted on this
> person's phone. That credential and its `admin_users` row (never signed in,
> token never used) were deleted at the owner's request so a fresh invitation
> can be issued; the spent invite row is kept as the record.

---

## 7. Admin passwords and auth email

### How it works

- **Changing a password** — sidebar footer → **Settings**. The browser proves the
  current password to Supabase Auth and updates it there; no Help24 server sees
  it. Supabase ends every *other* session of the account (GoTrue
  `UpdatePassword` → `LogoutAllExceptMe`; access tokens already issued stay
  cryptographically valid until they expire, but the dashboard checks the
  session on every request, so other devices are out on their next click). The
  dashboard then re-mints the arbitration token.
- **Forgotten password** — **Forgot password?** on the sign-in page or **Email me
  a reset link** in Settings. Supabase sends its own one-time link; it returns to
  `/auth/callback`, then `/reset-password`. The link completes only in the browser
  that asked for it (PKCE); elsewhere the page says so.
- **Invitations** — see §1 step 2. The backend does not email invitations: the
  super admin copies the link from **Admin Roles**. The Supabase "Invite user"
  template below only exists so nothing Supabase-branded can ever go out.

### Three separate things, three separate settings

| What | Value | Where it is set |
|---|---|---|
| Who the email is **from** | `Help24 Security <security@help24.co.ke>` | Supabase SMTP settings + Resend domain |
| The host in the email's **link** | the Supabase project host (`taohzhnvaitrpxcyjflq.supabase.co`), or a Supabase custom domain | Supabase (custom domain is optional) |
| Where the link **returns** | `https://admin.help24.co.ke/auth/callback` | Supabase URL configuration |

**`auth.help24.co.ke` cannot be used for Supabase.** Public DNS (2026-10-10):
it is a CNAME to Firebase Hosting (`help24-24410.web.app`) carrying Firebase's
verification TXT, its SPF (`include:_spf.firebasemail.com`), two Firebase DKIM
CNAMEs and its own DMARC — it is Firebase's auth domain *and* the sender of the
app's emails. A Supabase custom domain must itself be a CNAME, which cannot share
a name with anything. If the link host must be Help24's, use a new name —
`auth-admin.help24.co.ke` is unused — and leave `auth.help24.co.ke` alone.

### Production checklist

State: **A** implemented and locally verified · **B** needs production dashboard
or provider access · **C** verified against production.

| # | Item | State |
|---|---|---|
| 1 | Seven branded templates generated and tested (`admin-dashboard/supabase-auth-emails/html/`, subjects in `manifest.json`) | A |
| 2 | Recovery flow, invitation hand-off, Settings — `npm test` and `npm run test:e2e` in `admin-dashboard` | A |
| 3 | Supabase currently sends with its default mailer — auth log 2026-10-10 08:40 UTC: `mail.send`, `mail_from: noreply@mail.app.supabase.io` | C (current state, not the target) |
| 4 | `auth.help24.co.ke` belongs to Firebase; `auth-admin.help24.co.ke` is free — public DNS | C |
| 5 | No outbound provider exists for `@help24.co.ke` (apex: Cloudflare Email Routing only; no `send.` records, no `resend._domainkey`) — public DNS | C |
| 6 | Resend account + domain `help24.co.ke` verified (DNS below) | B |
| 7 | Cloudflare Email Routing rule `security@help24.co.ke` → the team inbox, so replies and "this wasn't me" reach someone | B |
| 8 | Supabase custom SMTP (values below) | B |
| 9 | Supabase Site URL and Redirect URLs (values below) — current values cannot be read from the repo | B |
| 10 | Templates and subjects pasted into Supabase | B |
| 11 | "Password changed" security notification enabled | B |
| 12 | DMARC at the apex | B (recommended) |
| 13 | Supabase custom domain `auth-admin.help24.co.ke` | B (optional, paid) |
| 14 | Smoke test passed in production | B |

**6 — Resend domain.** In Resend, add `help24.co.ke` (region `eu-west-1`, nearest
the project). Copy the records Resend shows into Cloudflare DNS, **DNS only**
(grey cloud). For a domain added before August 2026 Resend issues:

```dns
resend._domainkey.help24.co.ke.  TXT  "p=<DKIM public key from Resend>"
send.help24.co.ke.               MX   10 feedback-smtp.eu-west-1.amazonses.com.
send.help24.co.ke.               TXT  "v=spf1 include:amazonses.com ~all"
```

Newer domains may instead show two CNAMEs on `send` and `rsend` — use exactly
what the dashboard shows. **Do not change** the apex MX or SPF (Cloudflare Email
Routing) or anything under `auth.help24.co.ke`. Create an API key with
*sending access* limited to `help24.co.ke`.

**8 — Supabase → Authentication → Emails → SMTP Settings.**

| Field | Value |
|---|---|
| Enable custom SMTP | on |
| Sender email | `security@help24.co.ke` |
| Sender name | `Help24 Security` |
| Host | `smtp.resend.com` |
| Port | `465` |
| Username | `resend` |
| Password | the Resend API key — paste it here only; never in the repo, a ticket or a chat |
| Minimum interval per user | `60` seconds (default) |

Turning SMTP on lifts Supabase's built-in limit (2 emails an hour, team members
only) to 30 an hour (Authentication → Rate Limits). That is plenty for admins.

**9 — Supabase → Authentication → URL Configuration.** Site URL
`https://admin.help24.co.ke`. Redirect URLs: exactly
`https://admin.help24.co.ke/auth/callback` — no wildcards. Supabase silently
sends any link whose `redirectTo` is not allowed to the Site URL instead. For
local development against production, add the exact
`http://localhost:3001/auth/callback` only while needed.

**10 — Templates.** Authentication → Emails → Templates. For each entry in
`manifest.json`, set the subject and paste the matching `html/<key>.html`. Keys:
`recovery`, `invite`, `reauthentication`, `magic_link`, `email_change`,
`confirmation`, `password_changed_notification` (under security
notifications). The same fields exist on the Management API
(`PATCH /v1/projects/{ref}/config/auth`; names in `manifest.json`). Supabase
sends HTML only — there is no plain-text part to set; each template prints its
link as text so it still works with markup stripped. Do **not** add an `[auth]`
section to `supabase/config.toml` to manage these: a later `supabase config push`
would reset every unspecified auth setting to the CLI default.

**12 — DMARC.** `_dmarc.help24.co.ke TXT "v=DMARC1; p=none; rua=mailto:dmarc@help24.co.ke"`
(add a routing rule for `dmarc@`, or drop `rua`). Tighten to `quarantine` after a
few clean weeks.

**13 — Custom domain (optional).** A paid add-on (US$10/month, paid plans only),
one per project, project-wide (REST and storage answer on it too). CNAME
`auth-admin.help24.co.ke` → `taohzhnvaitrpxcyjflq.supabase.co.` plus the
`_acme-challenge` TXT Supabase issues. Without it the email's link shows the
Supabase project host; the sender, wording and return address are Help24's
regardless.

### Safe production smoke test

Use **your own** admin account; never another admin's.

1. After 6–10: sign out, **Forgot password?** with your address.
2. In the email check: From `Help24 Security <security@help24.co.ke>`, subject
   "Reset your Help24 admin password", Help24 layout. Gmail → *Show original*:
   SPF, DKIM (`d=help24.co.ke`) and DMARC all **PASS**.
3. Supabase → Logs → Auth: the `mail.send` line shows `mail_from: security@help24.co.ke`.
4. Stop here for a zero-impact check — the unused link expires on its own. To
   finish, open it **in the same browser**, set a new password, and confirm you
   land in the dashboard and that an older session elsewhere is signed out.
5. Optional invite check: invite an address you control, accept it, confirm the
   "activation pending" message, then revoke it under **Admin Roles**.

### Deployment order

1. Resend domain + DNS (6); wait for **Verified**. Routing rule (7).
2. Supabase URL configuration (9).
3. Ship the dashboard: commit, push, then `npx vercel --prod --yes` from
   `admin-dashboard/` — it does not auto-deploy, and it ships the working tree.
4. Templates (10) and the password-changed notification (11).
5. Custom SMTP (8) — last, once the domain is verified, so no mail goes out
   from an unverified sender.
6. Smoke test.

### Rollback

- **Email delivery fails** — turn custom SMTP off in Supabase. Mail falls back
  to the built-in sender (team members only, 2 an hour); the Help24 templates
  keep working with it. DNS records can stay — they are inert on their own.
- **A template is wrong** — paste the previous content back, or "Reset to
  default" on that template.
- **Invitation acceptance or the reset flow misbehaves** — Vercel → the
  `help24-admin-dashboard` project → Deployments → promote the previous
  production deployment. That restores the old behaviour, including the old
  reset link (which never set a password); leave Supabase settings as they are.
- **Redirect URLs** — leave them; an exact callback URL is harmless if unused.
