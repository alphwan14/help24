-- =============================================================================
-- Migration 127: partner agents, and which agent brought each member
-- =============================================================================
-- ADDITIVE. Three tables and two functions; writes nothing at apply time.
-- Phase P1 of docs/partner-portal-plan.md: CAPTURE. Agents are paid per
-- qualified member, so the credit is set by one server-side function with the
-- rules below, never written by a client directly.
--
-- 1. partner_agents
--    One row per agent (onboarding / marketing / research): a code like
--    H24-7K3Q, a display name members see when they enter it, an optional
--    link to the agent's own Help24 account and phone (to refuse
--    self-credit), and active/suspended. Created from the admin dashboard
--    (phase P2); nothing creates them here.
--
-- 2. member_attribution
--    At most ONE agent per member (primary key member_id), how the code
--    arrived (code typed, link, QR), and when.
--
-- 3. member_attribution_events
--    Append-only: every credit and every change, with the agent before and
--    after — the record a disputed payout is settled from.
--
-- claim_agent_code(p_code, p_method) — the only writer. Called by the app as
-- the signed-in member (JWT user_id = users.id):
--   * the code must belong to an ACTIVE agent;
--   * never the agent's own account or phone number;
--   * only within 72 hours of the member joining — then the credit is
--     locked. Members who joined before this migration cannot be credited;
--   * the same code again is a no-op; a different code inside the window
--     moves the credit (and is logged).
-- my_agent_credit() — the member's own credit and whether it can still change.
--
-- Rollback (the app shows "agent codes aren't available yet" without them):
--   DROP FUNCTION IF EXISTS public.claim_agent_code(text, text), public.my_agent_credit();
--   DROP TABLE IF EXISTS public.member_attribution_events, public.member_attribution, public.partner_agents;
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.partner_agents (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- No 0/O/1/I: codes are read aloud and copied by hand.
  code          text        NOT NULL UNIQUE CHECK (code ~ '^H24-[A-HJ-NP-Z2-9]{4,6}$'),
  kind          text        NOT NULL CHECK (kind IN ('onboarding', 'marketing', 'research')),
  display_name  text        NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 2 AND 80),
  member_id     text        REFERENCES public.users(id) ON DELETE SET NULL,
  phone         text,
  status        text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    uuid        REFERENCES public.admin_users(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS public.member_attribution (
  member_id   text        PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  agent_id    uuid        NOT NULL REFERENCES public.partner_agents(id) ON DELETE RESTRICT,
  code        text        NOT NULL,
  method      text        NOT NULL CHECK (method IN ('code', 'link', 'qr')),
  claimed_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_member_attribution_agent
  ON public.member_attribution (agent_id, claimed_at DESC);

CREATE TABLE IF NOT EXISTS public.member_attribution_events (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id          text        NOT NULL,
  agent_id           uuid        NOT NULL REFERENCES public.partner_agents(id) ON DELETE RESTRICT,
  previous_agent_id  uuid        REFERENCES public.partner_agents(id) ON DELETE RESTRICT,
  method             text        NOT NULL,
  action             text        NOT NULL CHECK (action IN ('credited', 'changed')),
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_member_attribution_events_member
  ON public.member_attribution_events (member_id, created_at DESC);

DROP TRIGGER IF EXISTS trg_member_attribution_events_append_only ON public.member_attribution_events;
CREATE TRIGGER trg_member_attribution_events_append_only
  BEFORE UPDATE OR DELETE ON public.member_attribution_events
  FOR EACH ROW EXECUTE FUNCTION public.fn_admin_append_only();
DROP TRIGGER IF EXISTS trg_member_attribution_events_no_truncate ON public.member_attribution_events;
CREATE TRIGGER trg_member_attribution_events_no_truncate
  BEFORE TRUNCATE ON public.member_attribution_events
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_admin_append_only();

-- Digits only, Kenyan local numbers as 254…: the comparison the self-credit
-- rule needs, whatever form either number was typed in.
CREATE OR REPLACE FUNCTION public.fn_phone_key(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN d ~ '^0[17][0-9]{8}$' THEN '254' || substr(d, 2)
    WHEN d ~ '^[17][0-9]{8}$'  THEN '254' || d
    ELSE nullif(d, '')
  END
  FROM (SELECT regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') AS d) s;
$$;

CREATE OR REPLACE FUNCTION public.claim_agent_code(p_code text, p_method text DEFAULT 'code')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    text := auth.jwt() ->> 'user_id';
  v_raw    text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_code   text;
  v_member public.users%ROWTYPE;
  v_agent  public.partner_agents%ROWTYPE;
  v_prev   public.member_attribution%ROWTYPE;
BEGIN
  IF v_uid IS NULL OR v_uid = '' OR coalesce(auth.jwt() ->> 'role', '') <> 'authenticated' THEN
    RAISE EXCEPTION 'HELP24_AGENT_SIGNED_OUT: sign in to add an agent code' USING ERRCODE = '42501';
  END IF;
  IF p_method IS NULL OR p_method NOT IN ('code', 'link', 'qr') THEN
    RAISE EXCEPTION 'HELP24_AGENT_INVALID: unknown method' USING ERRCODE = '22023';
  END IF;

  -- "h24 7k3q", "H24-7K3Q" and "7K3Q" all mean H24-7K3Q.
  IF v_raw LIKE 'H24%' THEN v_raw := substr(v_raw, 4); END IF;
  v_code := 'H24-' || v_raw;

  SELECT * INTO v_member FROM public.users WHERE id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_AGENT_NO_PROFILE: finish setting up your profile first' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_agent FROM public.partner_agents WHERE code = v_code;
  IF NOT FOUND OR v_agent.status <> 'active' THEN
    RAISE EXCEPTION 'HELP24_AGENT_CODE_UNKNOWN: we don''t recognise that code — check it with the person who gave it to you'
      USING ERRCODE = '22023';
  END IF;

  IF v_agent.member_id = v_uid
     OR (public.fn_phone_key(v_agent.phone) IS NOT NULL
         AND public.fn_phone_key(v_agent.phone) = public.fn_phone_key(coalesce(v_member.phone_number, v_member.phone))) THEN
    RAISE EXCEPTION 'HELP24_AGENT_SELF: an agent can''t use their own code' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_prev FROM public.member_attribution WHERE member_id = v_uid FOR UPDATE;
  IF FOUND AND v_prev.agent_id = v_agent.id THEN
    RETURN jsonb_build_object('status', 'unchanged', 'agent_name', v_agent.display_name, 'code', v_agent.code);
  END IF;

  IF v_member.created_at < now() - interval '72 hours' THEN
    RAISE EXCEPTION 'HELP24_AGENT_WINDOW_CLOSED: agent codes can only be added in your first 3 days on Help24'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.member_attribution (member_id, agent_id, code, method)
  VALUES (v_uid, v_agent.id, v_agent.code, p_method)
  ON CONFLICT (member_id) DO UPDATE
    SET agent_id = EXCLUDED.agent_id, code = EXCLUDED.code, method = EXCLUDED.method, updated_at = now();

  INSERT INTO public.member_attribution_events (member_id, agent_id, previous_agent_id, method, action)
  VALUES (v_uid, v_agent.id, v_prev.agent_id, p_method, CASE WHEN v_prev.agent_id IS NULL THEN 'credited' ELSE 'changed' END);

  RETURN jsonb_build_object(
    'status', CASE WHEN v_prev.agent_id IS NULL THEN 'credited' ELSE 'changed' END,
    'agent_name', v_agent.display_name,
    'code', v_agent.code
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.my_agent_credit()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid     text := auth.jwt() ->> 'user_id';
  v_joined  timestamptz;
  v_row     record;
BEGIN
  IF v_uid IS NULL OR v_uid = '' OR coalesce(auth.jwt() ->> 'role', '') <> 'authenticated' THEN
    RAISE EXCEPTION 'HELP24_AGENT_SIGNED_OUT: sign in first' USING ERRCODE = '42501';
  END IF;
  SELECT created_at INTO v_joined FROM public.users WHERE id = v_uid;
  SELECT a.code, a.method, a.claimed_at, g.display_name
    INTO v_row
    FROM public.member_attribution a JOIN public.partner_agents g ON g.id = a.agent_id
   WHERE a.member_id = v_uid;
  RETURN jsonb_build_object(
    'agent_name', v_row.display_name,
    'code', v_row.code,
    'method', v_row.method,
    'claimed_at', v_row.claimed_at,
    'window_ends_at', v_joined + interval '72 hours',
    'can_change', v_joined IS NOT NULL AND v_joined >= now() - interval '72 hours'
  );
END;
$$;

ALTER TABLE public.partner_agents            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_attribution        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_attribution_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.partner_agents, public.member_attribution, public.member_attribution_events
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.partner_agents     TO service_role;
GRANT SELECT                 ON public.member_attribution TO service_role;
GRANT SELECT                 ON public.member_attribution_events TO service_role;

REVOKE ALL ON FUNCTION public.claim_agent_code(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.my_agent_credit()            FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_phone_key(text)           FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_agent_code(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_agent_credit()            TO authenticated;

COMMIT;
