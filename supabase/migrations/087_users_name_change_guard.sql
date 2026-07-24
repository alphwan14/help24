-- =============================================================================
-- Migration 087 — Professional Profile PP-2: server-enforced name-change policy
-- =============================================================================
-- The Professional Profile lets users edit their display name. A name is a
-- TRUST SIGNAL: it is attached to completed jobs, reviews, chats and payments,
-- so rotating it freely is an abuse vector (apply as one person, get reviewed,
-- rename, repeat).
--
-- WHY THIS MUST LIVE IN POSTGRES
-- ------------------------------
-- Migration 011 grants `users_update_own`: a signed-in user may UPDATE their
-- own row directly from the client. A cooldown enforced only in Dart is
-- therefore decorative — anyone with the anon key and their own JWT could
-- bypass it. The rule belongs where the write lands.
--
-- WHAT THIS DOES
--   1. Adds `users.name_changed_at` (nullable — NULL = never changed).
--   2. Installs a BEFORE UPDATE trigger that:
--        * allows the change and stamps `name_changed_at = now()` when the
--          previous change was more than 30 days ago (or never),
--        * RAISES with the marker HELP24_NAME_COOLDOWN otherwise (the app maps
--          that marker to a calm "you can change it again in N days"),
--        * pins `name_changed_at` to its old value on every other UPDATE, so a
--          client cannot reset its own cooldown by writing the column.
--
-- SAFE + ADDITIVE for existing users: `name_changed_at` starts NULL for
-- everyone, which means EVERY existing user gets one immediate change. No row
-- is rewritten, no existing name is touched or validated retroactively, and
-- updates that do not change `name` are entirely unaffected.
--
-- Name SHAPE (letters only, first + last, no vanity handles) is validated in
-- the app (utils/name_validator.dart), not here: shape rules evolve with
-- product judgement and must not require a migration to tune. This trigger
-- owns exactly one thing — the rate limit — because that is the part the
-- client cannot be trusted with.
--
-- Rollback:
--   DROP TRIGGER IF EXISTS trg_users_name_change_guard ON public.users;
--   DROP FUNCTION IF EXISTS public.fn_users_name_change_guard();
--   ALTER TABLE public.users DROP COLUMN IF EXISTS name_changed_at;
-- =============================================================================

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS name_changed_at TIMESTAMPTZ;

COMMENT ON COLUMN public.users.name_changed_at IS
  'When the display name last changed. Owned by trg_users_name_change_guard; never written by clients. NULL = never changed.';

CREATE OR REPLACE FUNCTION public.fn_users_name_change_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  cooldown CONSTANT INTERVAL := INTERVAL '30 days';
  next_allowed TIMESTAMPTZ;
BEGIN
  -- Not a name change (the overwhelmingly common case: avatar, bio,
  -- profession, presence, prefs). Freeze the stamp so it cannot be forged,
  -- and get out of the way.
  IF NEW.name IS NOT DISTINCT FROM OLD.name THEN
    NEW.name_changed_at := OLD.name_changed_at;
    RETURN NEW;
  END IF;

  -- First-ever change is always allowed, including for every user who existed
  -- before this migration.
  IF OLD.name_changed_at IS NOT NULL THEN
    next_allowed := OLD.name_changed_at + cooldown;
    IF now() < next_allowed THEN
      RAISE EXCEPTION
        'HELP24_NAME_COOLDOWN: name can change again after %', next_allowed
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  NEW.name_changed_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_name_change_guard ON public.users;
CREATE TRIGGER trg_users_name_change_guard
  BEFORE UPDATE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_users_name_change_guard();

COMMENT ON FUNCTION public.fn_users_name_change_guard() IS
  'Rate-limits display-name changes to one per 30 days and owns users.name_changed_at. RLS lets users update their own row, so this rule cannot live in the client.';
