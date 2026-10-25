-- 122 — Admin identity linking without SQL.
--
-- Until now a dashboard credential (auth.users) became a Help24 admin only when a
-- super admin hand-ran the runbook's INSERT into user_auth_identities. Nothing
-- in the product said a login was waiting, so a correctly-signed-in admin was
-- turned away 53 times in one evening (2026-10-25) with no one told. This adds
-- what the backend needs to (a) notice a login nobody has linked, (b) let a
-- super admin link it from the dashboard, and (c) let an invitation name the
-- Help24 person it is for, so accepting it links the login in the same step.
--
-- None of this links anything by itself. Every link still names a human
-- (linked_by), and an email match is never treated as proof.
--
-- Additive and reversible:
--   drop function public.admin_link_dashboard_login(uuid, text, text);
--   drop function public.admin_unlinked_dashboard_logins(integer);
--   alter table public.admin_invites drop column help24_user_id;

-- ── (c) An invitation can name its person ──────────────────────────────────
-- Nullable: invitations issued before this migration name nobody, and accepting
-- one of those behaves exactly as before (the login waits to be linked).
alter table public.admin_invites
  add column if not exists help24_user_id text
    references public.users(id) on delete set null;

comment on column public.admin_invites.help24_user_id is
  'The Help24 person (public.users.id) this invitation is for. Chosen by the '
  'super admin who issued it; accepting the invite links the new dashboard '
  'login to this person. NULL on invitations issued before migration 122.';

-- ── (a) Logins waiting to be linked ────────────────────────────────────────
-- auth.users holds DASHBOARD credentials only (the app signs in with Firebase),
-- so every row here is somebody's admin login. A row with no supabase link is
-- one the middleware will refuse, however correct the password. Recent sign-ins
-- and recent creations both count: an accepted invitation that never signed in
-- is as stuck as a login that keeps trying.
create or replace function public.admin_unlinked_dashboard_logins(p_days integer default 30)
returns table (
  auth_subject    uuid,
  email           text,
  created_at      timestamptz,
  last_sign_in_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select u.id, u.email::text, u.created_at, u.last_sign_in_at
  from auth.users u
  where u.deleted_at is null
    and (u.last_sign_in_at > now() - make_interval(days => p_days)
         or u.created_at   > now() - make_interval(days => p_days))
    and not exists (
      select 1 from public.user_auth_identities i
      where i.provider = 'supabase' and i.subject = u.id::text
    )
  order by coalesce(u.last_sign_in_at, u.created_at) desc
  limit 200;
$$;

-- ── (b) Link one login to one person ───────────────────────────────────────
-- Atomic, and explicit about every refusal so the dashboard can say which one.
-- The two uniqueness rules already on user_auth_identities do the real work —
-- PK (provider, subject): a login belongs to at most one person;
-- UNIQUE (help24_user_id, provider): a person has at most one dashboard login —
-- this function only turns their violations into named outcomes.
create or replace function public.admin_link_dashboard_login(
  p_auth_subject   uuid,
  p_help24_user_id text,
  p_linked_by      text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_role  text;
begin
  if p_linked_by is null or length(trim(p_linked_by)) = 0 then
    return jsonb_build_object('outcome', 'linked_by_required');
  end if;

  select u.email::text into v_email
  from auth.users u where u.id = p_auth_subject and u.deleted_at is null;
  if not found then
    return jsonb_build_object('outcome', 'no_login');
  end if;

  select p.role into v_role from public.users p where p.id = p_help24_user_id;
  if not found then
    return jsonb_build_object('outcome', 'no_person');
  end if;

  if exists (select 1 from public.user_auth_identities i
             where i.provider = 'supabase' and i.subject = p_auth_subject::text) then
    return jsonb_build_object('outcome', 'login_already_linked');
  end if;

  if exists (select 1 from public.user_auth_identities i
             where i.provider = 'supabase' and i.help24_user_id = p_help24_user_id) then
    return jsonb_build_object('outcome', 'person_already_has_login');
  end if;

  insert into public.user_auth_identities (help24_user_id, provider, subject, linked_by)
  values (p_help24_user_id, 'supabase', p_auth_subject::text, trim(p_linked_by));

  return jsonb_build_object(
    'outcome', 'linked',
    'login_email', v_email,
    'person_role', coalesce(v_role, 'user')
  );
exception
  when unique_violation then
    -- A concurrent link won the race; report it as the state it left behind.
    return jsonb_build_object('outcome', 'login_already_linked');
end;
$$;

-- Backend only. Neither function may be reachable with the publishable key.
revoke all on function public.admin_unlinked_dashboard_logins(integer) from public, anon, authenticated;
revoke all on function public.admin_link_dashboard_login(uuid, text, text) from public, anon, authenticated;
grant execute on function public.admin_unlinked_dashboard_logins(integer) to service_role;
grant execute on function public.admin_link_dashboard_login(uuid, text, text) to service_role;
