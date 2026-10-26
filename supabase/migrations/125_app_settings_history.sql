-- =============================================================================
-- Migration 125: who changed the app's controls, when, and why
-- =============================================================================
-- ADDITIVE. One append-only table and one server-only function; alters nothing
-- that exists, and writes nothing at apply time.
--
-- The client configuration plane (app_settings: kill switches, maintenance,
-- announcement, min_version, tuning) has been editable only by hand-written
-- SQL, which records nothing about who changed it or why. The dashboard's App
-- controls page now edits it through PATCH /admin/config/:key, and every edit
-- goes through admin_set_app_setting(...) below: the new value and its history
-- row are written in ONE transaction, so a change can never land unrecorded.
--
-- 1. app_settings_history
--    Append-only: key, the value before and after, the reason, and the admin
--    (id, email, role at the time) and request id.
--
-- 2. admin_set_app_setting(...)
--    Checks the caller is a senior_admin or super_admin (the backend checks
--    too — this is the floor), locks the current row, upserts the new value
--    and appends the history row.
--
-- Depends on 115 (moderation_assert_trusted, moderation_require_admin) and 117
-- (fn_admin_append_only).
--
-- Rollback (the backend falls back to a plain, unrecorded upsert without them,
-- and the App controls page says the history is unavailable):
--   DROP FUNCTION IF EXISTS public.admin_set_app_setting(uuid, text, jsonb, text, text);
--   DROP TABLE IF EXISTS public.app_settings_history;
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.app_settings_history (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  key             text        NOT NULL,
  previous_value  jsonb,
  new_value       jsonb       NOT NULL,
  reason          text        NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 5 AND 500),
  admin_id        uuid        NOT NULL REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  admin_email     text        NOT NULL,
  admin_role      text        NOT NULL,
  request_id      text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_app_settings_history_created
  ON public.app_settings_history (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_app_settings_history_key
  ON public.app_settings_history (key, created_at DESC);

DROP TRIGGER IF EXISTS trg_app_settings_history_append_only ON public.app_settings_history;
CREATE TRIGGER trg_app_settings_history_append_only
  BEFORE UPDATE OR DELETE ON public.app_settings_history
  FOR EACH ROW EXECUTE FUNCTION public.fn_admin_append_only();
DROP TRIGGER IF EXISTS trg_app_settings_history_no_truncate ON public.app_settings_history;
CREATE TRIGGER trg_app_settings_history_no_truncate
  BEFORE TRUNCATE ON public.app_settings_history
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_admin_append_only();

CREATE OR REPLACE FUNCTION public.admin_set_app_setting(
  p_admin_id   uuid,
  p_key        text,
  p_value      jsonb,
  p_reason     text,
  p_request_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin    public.admin_users%ROWTYPE;
  v_previous jsonb;
  v_reason   text := btrim(coalesce(p_reason, ''));
  v_id       uuid;
BEGIN
  PERFORM public.moderation_assert_trusted();
  v_admin := public.moderation_require_admin(p_admin_id);
  IF v_admin.role NOT IN ('senior_admin', 'super_admin') THEN
    RAISE EXCEPTION 'HELP24_CONFIG_FORBIDDEN: changing app controls needs a senior admin' USING ERRCODE = '42501';
  END IF;
  IF p_key IS NULL OR p_key !~ '^(ops|tuning)\.[a-z_]{3,40}$' THEN
    RAISE EXCEPTION 'HELP24_CONFIG_INVALID: unknown setting' USING ERRCODE = '22023';
  END IF;
  IF p_value IS NULL OR jsonb_typeof(p_value) <> 'object' THEN
    RAISE EXCEPTION 'HELP24_CONFIG_INVALID: the value must be a JSON object' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_reason) < 5 OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'HELP24_CONFIG_INVALID: give a reason, in 5 to 500 characters' USING ERRCODE = '22023';
  END IF;

  SELECT value INTO v_previous FROM public.app_settings WHERE key = p_key FOR UPDATE;

  INSERT INTO public.app_settings (key, value, updated_at)
  VALUES (p_key, p_value, now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;

  INSERT INTO public.app_settings_history
    (key, previous_value, new_value, reason, admin_id, admin_email, admin_role, request_id)
  VALUES
    (p_key, v_previous, p_value, v_reason, v_admin.id, v_admin.email, v_admin.role, p_request_id)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('history_id', v_id, 'changed', v_previous IS DISTINCT FROM p_value);
END;
$$;

ALTER TABLE public.app_settings_history ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.app_settings_history FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.app_settings_history TO service_role;

REVOKE ALL ON FUNCTION public.admin_set_app_setting(uuid, text, jsonb, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_app_setting(uuid, text, jsonb, text, text) TO service_role;

COMMIT;
