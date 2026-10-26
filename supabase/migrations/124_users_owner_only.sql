-- 124 — public.users is readable and writable only by its owner.
--
-- Until now any holder of the publishable key (it ships inside the app) could
-- read every member's row — email and phone number included — and insert a row
-- with any id and any email: email squatting (blocking the real owner's
-- profile), row spam, and wholesale export of contact details. The guard
-- trigger (fn_users_guard_privileged_columns) stopped privilege escalation,
-- not this.
--
-- What made it safe to close (all verified before applying):
--   * App 1.0.4+ never reads another person's row from `users` — other people
--     come from public_profiles (migration 123, runs with its owner's rights,
--     so it is unaffected) — and never writes its own row as `anon`.
--   * ops.min_version.hard = 1.0.4, so older apps are held at the update
--     screen; 1.0.5 is current.
--   * The backend and admin dashboard use the service role (bypasses RLS).
--   * No other table's policy, no view and no reachable invoker function
--     reads users with the caller's rights (pre-flight query, 2026-10-26).
--   * After applying, check as `anon`: `select count(*) from public.users`
--     returns 0 and an insert is refused; as a signed-in member, only their
--     own row is visible. (A rehearsal inside a rolled-back transaction was
--     prepared but not run — the tool permission prompt declined it.)
--
-- The JWT the app presents is minted by the exchange-firebase-token edge
-- function: role `authenticated`, user_id = sub = the Firebase uid, which is
-- users.id. The existing users_update_own policy already uses that claim.
--
-- Reversible: recreate the two "true" policies below (see 011 / 103).

-- ── Reads: your own row only ───────────────────────────────────────────────
drop policy if exists "Users are viewable by anon and authenticated" on public.users;
drop policy if exists users_select on public.users;

create policy users_select_own on public.users
  for select to authenticated
  using (id = (auth.jwt() ->> 'user_id'));

-- ── Inserts: only your own row, only signed in ─────────────────────────────
drop policy if exists "Users insert by anon and authenticated" on public.users;
drop policy if exists users_insert on public.users;

create policy users_insert_own on public.users
  for insert to authenticated
  with check (id = (auth.jwt() ->> 'user_id'));

-- users_update_own (authenticated, id = jwt user_id) is unchanged.

-- ── Legacy RPCs nothing calls ──────────────────────────────────────────────
-- Both run with the caller's rights, so the policies above already confine
-- them; revoking keeps them from being a way round any future change.
revoke execute on function public.get_user_by_id(text) from anon, authenticated;
revoke execute on function public.upsert_user(text, text, text, text) from anon, authenticated;
