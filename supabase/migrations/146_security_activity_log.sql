-- 146: Security activity log (super admins: Users > Security log).
--
-- ADDITIVE. One new table and three functions; nothing existing changes and no
-- data is written at apply.
--
-- What it adds:
--   1. public.security_events: an append-only record of security moments that
--      nothing recorded before. Console opened or refused, a Google sign-in an
--      admin gate refused, a failed password attempt on an admin or partner
--      address, and every real member sign-in (the moment Firebase signed them
--      in, not every hourly token refresh). With the IP address, device and,
--      where the host provides it, the country and city.
--   2. public.security_auth_events(): read access to Supabase Auth's own audit
--      log (auth.audit_log_entries) for the console. That is where admin and
--      partner sign-ins, sign-outs, password changes and reset requests are
--      already recorded, so they are read, not copied. Token refreshes are left
--      out: they are noise.
--   3. public.record_member_sign_in(): what the exchange-firebase-token edge
--      function calls. One row per Firebase sign-in (auth_time), however many
--      times that session refreshes its token.
--
-- Everything else the log shows is read from tables that already exist:
-- moderation_actions, admin_finance_actions, partner_admin_events,
-- post_type_changes, app_settings_history and user_auth_identities.
--
-- Access: service_role only (the console's server). RLS is on with no
-- policies, so the app's anon and member keys can neither read nor write.
-- No foreign keys on the people columns on purpose: a member's first sign-in
-- can arrive before their users row exists, and a removed admin's history must
-- outlive them. Names and emails are snapshots, as the other ledgers keep.

BEGIN;

CREATE TABLE IF NOT EXISTS public.security_events (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_at  timestamptz NOT NULL DEFAULT now(),
  -- Who did it: an admin of the console, a member of the app, a partner agent,
  -- or nobody we could name (a failed attempt on an unknown address is not
  -- recorded at all; see the console route).
  actor_kind   text        NOT NULL CHECK (actor_kind IN ('admin', 'member', 'partner', 'system')),
  admin_id     uuid,
  user_id      text,
  actor_email  text,
  actor_role   text,
  -- '<area>.<what>', e.g. 'console.opened', 'member.signed_in'.
  event        text        NOT NULL CHECK (event ~ '^[a-z_]+\.[a-z_]+$'),
  outcome      text        NOT NULL DEFAULT 'success' CHECK (outcome IN ('success', 'failure')),
  ip           inet,
  user_agent   text        CHECK (user_agent IS NULL OR char_length(user_agent) <= 512),
  country      text        CHECK (country IS NULL OR char_length(country) <= 64),
  city         text        CHECK (city IS NULL OR char_length(city) <= 128),
  -- Small structured facts (sign-in method, refusal reason). Never secrets.
  detail       jsonb       NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS security_events_time_idx   ON public.security_events (occurred_at DESC);
CREATE INDEX IF NOT EXISTS security_events_admin_idx  ON public.security_events (admin_id, occurred_at DESC) WHERE admin_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS security_events_member_idx ON public.security_events (user_id, occurred_at DESC) WHERE user_id IS NOT NULL;
-- One member sign-in row per Firebase session (see record_member_sign_in).
CREATE UNIQUE INDEX IF NOT EXISTS security_events_member_session_uniq
  ON public.security_events (user_id, (detail ->> 'auth_time'))
  WHERE event = 'member.signed_in';

ALTER TABLE public.security_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.security_events FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.security_events TO service_role;

-- Append-only, for every role the owner included: a security log that can be
-- edited is not evidence.
CREATE OR REPLACE FUNCTION public.security_events_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'security_events is append-only (% refused)', TG_OP
    USING ERRCODE = 'insufficient_privilege';
END;
$$;

DROP TRIGGER IF EXISTS security_events_no_update ON public.security_events;
CREATE TRIGGER security_events_no_update
  BEFORE UPDATE OR DELETE ON public.security_events
  FOR EACH ROW EXECUTE FUNCTION public.security_events_append_only();

DROP TRIGGER IF EXISTS security_events_no_truncate ON public.security_events;
CREATE TRIGGER security_events_no_truncate
  BEFORE TRUNCATE ON public.security_events
  FOR EACH STATEMENT EXECUTE FUNCTION public.security_events_append_only();

-- ── Supabase Auth's audit log, for the console ─────────────────────────────
-- auth.* is not exposed through the API, so the console reads it through this
-- function. Admin and partner accounts are the only Supabase Auth users (app
-- members sign in with Firebase), so this is their sign-in history.
CREATE OR REPLACE FUNCTION public.security_auth_events(p_before timestamptz DEFAULT NULL, p_limit integer DEFAULT 100)
RETURNS TABLE (
  id          uuid,
  occurred_at timestamptz,
  auth_id     text,
  email       text,
  action      text,
  provider    text,
  ip          text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT e.id,
         e.created_at,
         e.payload ->> 'actor_id',
         lower(e.payload ->> 'actor_username'),
         e.payload ->> 'action',
         e.payload -> 'traits' ->> 'provider',
         nullif(e.ip_address, '')
    FROM auth.audit_log_entries e
   WHERE e.created_at < coalesce(p_before, 'infinity'::timestamptz)
     AND coalesce(e.payload ->> 'action', '') NOT IN ('token_refreshed', 'token_revoked')
   ORDER BY e.created_at DESC
   LIMIT least(greatest(coalesce(p_limit, 100), 1), 500);
$$;

REVOKE ALL ON FUNCTION public.security_auth_events(timestamptz, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.security_auth_events(timestamptz, integer) TO service_role;

-- ── Member sign-ins, from exchange-firebase-token ──────────────────────────
-- The edge function swaps a Firebase ID token for a Supabase one about once an
-- hour per device. Firebase's auth_time only changes when the person actually
-- signs in, so keying on it turns hourly refreshes into one row per sign-in.
CREATE OR REPLACE FUNCTION public.record_member_sign_in(
  p_user_id    text,
  p_auth_time  bigint,
  p_provider   text DEFAULT NULL,
  p_ip         text DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_country    text DEFAULT NULL,
  p_city       text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ip inet;
BEGIN
  IF p_user_id IS NULL OR btrim(p_user_id) = '' OR p_auth_time IS NULL THEN
    RETURN;
  END IF;
  BEGIN
    v_ip := nullif(btrim(p_ip), '')::inet;
  EXCEPTION WHEN others THEN
    v_ip := NULL;
  END;

  INSERT INTO public.security_events
    (occurred_at, actor_kind, user_id, event, ip, user_agent, country, city, detail)
  VALUES (
    to_timestamp(p_auth_time),
    'member',
    left(p_user_id, 128),
    'member.signed_in',
    v_ip,
    left(p_user_agent, 512),
    left(p_country, 64),
    left(p_city, 128),
    jsonb_build_object('auth_time', p_auth_time::text, 'provider', left(coalesce(p_provider, ''), 40))
  )
  ON CONFLICT (user_id, (detail ->> 'auth_time')) WHERE event = 'member.signed_in' DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION public.record_member_sign_in(text, bigint, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_member_sign_in(text, bigint, text, text, text, text, text) TO service_role;

COMMIT;
