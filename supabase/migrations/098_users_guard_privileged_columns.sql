-- 098 — Stop privilege escalation and reputation forgery through public.users.
--
-- WHY THIS EXISTS (confirmed live, 2026-08-06):
-- RLS on public.users carries UPDATE/INSERT policies with USING/WITH CHECK
-- `true` for {public} and {anon,authenticated}, and `anon` holds table-level
-- grants. The publishable key ships inside the Android app, so it is public.
-- A single unauthenticated PATCH with that key set `is_verified = true` on a
-- real row. `role` is writable the same way, and the admin dashboard gates on
-- public.users.role (by email) before querying with service_role — so one
-- column flip converts a public key into unrestricted database access.
--
-- WHY A TRIGGER AND NOT AN RLS FIX:
-- Owner-scoped RLS (migration 011) would break deployed clients: sign-up writes
-- can race the Firebase->Supabase token exchange, and the admin dashboard wrote
-- is_banned from the browser with a Supabase Auth JWT that carries no `user_id`
-- claim. This guard closes the escalation without touching a single policy, so
-- no existing flow changes.
--
-- WHY VALUES ARE COMPARED, NOT REVOKED:
-- The mobile client upserts with `onConflict: id`, which restates `email` on
-- every sign-in. A column-level REVOKE would refuse that statement even though
-- nothing changes. `IS DISTINCT FROM` lets the restatement through and stops
-- only real changes.
--
-- PAIRED CODE CHANGE (must be deployed FIRST):
-- admin-dashboard BanToggle now calls the `setUserBanned` server action
-- (service_role, server-side admin check) instead of writing from the browser.
-- Deploying this migration before that change would break suspend/reinstate.
--
-- ROLLBACK:
--   DROP TRIGGER IF EXISTS trg_users_guard_privileged_columns ON public.users;
--   DROP FUNCTION IF EXISTS public.fn_users_guard_privileged_columns();
-- Touches no rows, so there is no rollback window and no backup dependency.

CREATE OR REPLACE FUNCTION public.fn_users_guard_privileged_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_jwt_role text;
BEGIN
  -- Trusted callers pass straight through: the service_role key (admin
  -- dashboard server actions) and owner/direct connections (SQL editor,
  -- migrations, and SECURITY DEFINER triggers such as handle_new_auth_user).
  v_jwt_role := COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '');

  IF v_jwt_role = 'service_role'
     OR current_user IN ('postgres', 'supabase_admin', 'service_role') THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- Coerce, never refuse: a sign-up must not fail because of this guard.
    -- A client simply does not get to choose its own privileges.
    NEW.role                 := 'user';
    NEW.is_banned            := false;
    NEW.is_verified          := false;
    NEW.average_rating       := NULL;
    NEW.total_reviews        := NULL;
    NEW.completed_jobs_count := NULL;
    RETURN NEW;
  END IF;

  IF NEW.id                   IS DISTINCT FROM OLD.id
  OR NEW.email                IS DISTINCT FROM OLD.email
  OR NEW.role                 IS DISTINCT FROM OLD.role
  OR NEW.is_banned            IS DISTINCT FROM OLD.is_banned
  OR NEW.is_verified          IS DISTINCT FROM OLD.is_verified
  OR NEW.average_rating       IS DISTINCT FROM OLD.average_rating
  OR NEW.total_reviews        IS DISTINCT FROM OLD.total_reviews
  OR NEW.completed_jobs_count IS DISTINCT FROM OLD.completed_jobs_count THEN
    RAISE EXCEPTION 'help24_privileged_column_change_refused'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_guard_privileged_columns ON public.users;
CREATE TRIGGER trg_users_guard_privileged_columns
  BEFORE INSERT OR UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.fn_users_guard_privileged_columns();

COMMENT ON FUNCTION public.fn_users_guard_privileged_columns() IS
  'Refuses changes to role/is_banned/is_verified/reputation/email/id from untrusted callers; coerces them on INSERT. service_role and owner connections bypass.';
