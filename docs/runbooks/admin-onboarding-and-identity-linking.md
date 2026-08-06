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

2. Create their dashboard credential (Supabase Auth account) the usual way —
   dashboard invite, or Supabase Studio → Authentication → Add user. Note the
   resulting `auth.users.id`.

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
