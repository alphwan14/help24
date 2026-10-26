-- =============================================================================
-- Migration 128: the partner portal — agent logins, invitations, and progress
-- =============================================================================
-- ADDITIVE. Phase P2 of docs/partner-portal-plan.md. Depends on 115
-- (moderation_assert_trusted, moderation_require_admin), 117
-- (fn_admin_append_only) and 127 (partner_agents, member_attribution).
--
-- 1. member_active_days
--    Which days each member used the app. The "qualified member" rule counts
--    DISTINCT days, and until now only the latest moment was kept
--    (users.last_seen / last_login). A trigger on users fills it as the app's
--    heartbeat and sign-ins write those columns — nothing in the app changes.
--    Backfilled with the one day each member is known to have been active.
--
-- 2. partner_logins / partner_invites
--    A partner signs in to partners.help24.co.ke with their OWN Supabase Auth
--    login, linked here to their partner_agents row by auth subject — never by
--    email, and never the admin role (the admin gate refuses them). An admin
--    issues a one-time invitation; only its SHA-256 is stored, so a leaked
--    table or log cannot be replayed.
--
-- 3. partner_admin_events
--    Append-only: agents created, suspended, reactivated, invitations issued,
--    logins linked — who, when, why.
--
-- 4. partner_member_progress (view)
--    Every credited member's progress toward QUALIFYING, computed in one place
--    for the partner portal, the admin dashboard and, later, statements:
--      qualified = good standing (not suspended/banned)
--                  AND (used the app on 2+ distinct days in their first 14,
--                       OR posted or sent an offer in their first 14 days).
--    Whether they signed in with a verified phone or Google is checked
--    separately before any payment (phase P5) — it lives in Firebase.
--
-- Functions (service role only — called by the dashboard's server code after
-- it has confirmed the admin through the backend; the database re-checks):
--   admin_create_partner_agent, admin_set_partner_status,
--   admin_issue_partner_invite, partner_accept_invite.
--
-- Rollback:
--   DROP VIEW IF EXISTS public.partner_member_progress;
--   DROP FUNCTION IF EXISTS public.partner_invite_preview(text), public.partner_accept_invite(text, uuid),
--     public.admin_issue_partner_invite(uuid, uuid, text, integer),
--     public.admin_set_partner_status(uuid, uuid, text, text),
--     public.admin_create_partner_agent(uuid, text, text, text, text),
--     public.fn_member_active_day();
--   DROP TRIGGER IF EXISTS trg_users_member_active_day ON public.users;
--   DROP TABLE IF EXISTS public.partner_admin_events, public.partner_invites,
--     public.partner_logins, public.member_active_days;
--   ALTER TABLE public.partner_agents DROP COLUMN IF EXISTS email;
-- =============================================================================

BEGIN;

-- ── 1. Active days ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.member_active_days (
  member_id  text NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  day        date NOT NULL,
  PRIMARY KEY (member_id, day)
);

-- Days are Nairobi days: a member active at 01:00 EAT was active on that
-- Kenyan date, not the UTC one before it.
CREATE OR REPLACE FUNCTION public.fn_member_active_day()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_at timestamptz := greatest(coalesce(NEW.last_seen, '-infinity'), coalesce(NEW.last_login, '-infinity'));
BEGIN
  IF v_at = '-infinity' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE'
     AND NEW.last_seen IS NOT DISTINCT FROM OLD.last_seen
     AND NEW.last_login IS NOT DISTINCT FROM OLD.last_login THEN
    RETURN NEW;
  END IF;
  INSERT INTO public.member_active_days (member_id, day)
  VALUES (NEW.id, (v_at AT TIME ZONE 'Africa/Nairobi')::date)
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_member_active_day ON public.users;
CREATE TRIGGER trg_users_member_active_day
  AFTER INSERT OR UPDATE OF last_seen, last_login ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.fn_member_active_day();

INSERT INTO public.member_active_days (member_id, day)
SELECT id, (last_seen AT TIME ZONE 'Africa/Nairobi')::date FROM public.users WHERE last_seen IS NOT NULL
UNION
SELECT id, (last_login AT TIME ZONE 'Africa/Nairobi')::date FROM public.users WHERE last_login IS NOT NULL
ON CONFLICT DO NOTHING;

-- ── 2. Logins and invitations ───────────────────────────────────────────────
ALTER TABLE public.partner_agents ADD COLUMN IF NOT EXISTS email text
  CHECK (email IS NULL OR email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$');
CREATE UNIQUE INDEX IF NOT EXISTS uq_partner_agents_email ON public.partner_agents (lower(email)) WHERE email IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.partner_logins (
  auth_subject  uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  agent_id      uuid        NOT NULL UNIQUE REFERENCES public.partner_agents(id) ON DELETE CASCADE,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.partner_invites (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id    uuid        NOT NULL REFERENCES public.partner_agents(id) ON DELETE CASCADE,
  token_hash  text        NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  expires_at  timestamptz NOT NULL,
  used_at     timestamptz,
  created_by  uuid        REFERENCES public.admin_users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_partner_invites_agent ON public.partner_invites (agent_id, created_at DESC);

-- ── 3. Admin actions ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.partner_admin_events (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id     uuid        NOT NULL REFERENCES public.partner_agents(id) ON DELETE RESTRICT,
  action       text        NOT NULL CHECK (action IN ('created', 'suspended', 'reactivated', 'invite_issued', 'login_linked')),
  reason       text,
  admin_id     uuid        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  admin_email  text,
  admin_role   text,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_partner_admin_events_agent ON public.partner_admin_events (agent_id, created_at DESC);

DROP TRIGGER IF EXISTS trg_partner_admin_events_append_only ON public.partner_admin_events;
CREATE TRIGGER trg_partner_admin_events_append_only
  BEFORE UPDATE OR DELETE ON public.partner_admin_events
  FOR EACH ROW EXECUTE FUNCTION public.fn_admin_append_only();
DROP TRIGGER IF EXISTS trg_partner_admin_events_no_truncate ON public.partner_admin_events;
CREATE TRIGGER trg_partner_admin_events_no_truncate
  BEFORE TRUNCATE ON public.partner_admin_events
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_admin_append_only();

-- ── 4. Progress ─────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.partner_member_progress
WITH (security_invoker = true) AS
SELECT
  a.member_id,
  a.agent_id,
  a.method,
  a.claimed_at,
  u.created_at AS joined_at,
  u.created_at + interval '14 days' AS window_ends_at,
  (SELECT count(*)::int FROM public.member_active_days d
    WHERE d.member_id = a.member_id
      AND d.day BETWEEN (u.created_at AT TIME ZONE 'Africa/Nairobi')::date
                    AND (u.created_at AT TIME ZONE 'Africa/Nairobi')::date + 13) AS active_days,
  (SELECT count(*)::int FROM public.posts p
    WHERE p.author_user_id = a.member_id AND p.created_at < u.created_at + interval '14 days') AS posts_14d,
  (SELECT count(*)::int FROM public.applications x
    WHERE x.applicant_user_id = a.member_id AND x.created_at < u.created_at + interval '14 days') AS offers_14d,
  coalesce(s.account_status, 'active') AS account_status
FROM public.member_attribution a
JOIN public.users u ON u.id = a.member_id
LEFT JOIN public.moderation_account_state s ON s.user_id = a.member_id;

-- ── Functions ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_create_partner_agent(
  p_admin_id uuid, p_display_name text, p_kind text, p_email text, p_phone text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin  public.admin_users%ROWTYPE;
  v_name   text := btrim(coalesce(p_display_name, ''));
  v_email  text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_phone  text := nullif(btrim(coalesce(p_phone, '')), '');
  v_alpha  text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code   text;
  v_id     uuid;
  v_try    int := 0;
BEGIN
  PERFORM public.moderation_assert_trusted();
  v_admin := public.moderation_require_admin(p_admin_id);
  IF v_admin.role NOT IN ('senior_admin', 'super_admin') THEN
    RAISE EXCEPTION 'HELP24_PARTNER_FORBIDDEN: adding agents needs a senior admin' USING ERRCODE = '42501';
  END IF;
  IF char_length(v_name) < 2 OR char_length(v_name) > 80 THEN
    RAISE EXCEPTION 'HELP24_PARTNER_INVALID: give the agent''s name, 2 to 80 characters' USING ERRCODE = '22023';
  END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('onboarding', 'marketing', 'research') THEN
    RAISE EXCEPTION 'HELP24_PARTNER_INVALID: choose onboarding, marketing or research' USING ERRCODE = '22023';
  END IF;
  IF v_email IS NOT NULL AND EXISTS (SELECT 1 FROM public.partner_agents WHERE lower(email) = v_email) THEN
    RAISE EXCEPTION 'HELP24_PARTNER_CONFLICT: another agent already uses that email' USING ERRCODE = '23505';
  END IF;

  LOOP
    v_try := v_try + 1;
    v_code := 'H24-' || (
      SELECT string_agg(substr(v_alpha, 1 + floor(random() * length(v_alpha))::int, 1), '')
      FROM generate_series(1, CASE WHEN v_try > 20 THEN 5 ELSE 4 END)
    );
    BEGIN
      INSERT INTO public.partner_agents (code, kind, display_name, phone, email, created_by)
      VALUES (v_code, p_kind, v_name, v_phone, v_email, v_admin.id)
      RETURNING id INTO v_id;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      IF v_try > 40 THEN RAISE; END IF;
    END;
  END LOOP;

  INSERT INTO public.partner_admin_events (agent_id, action, admin_id, admin_email, admin_role)
  VALUES (v_id, 'created', v_admin.id, v_admin.email, v_admin.role);

  RETURN jsonb_build_object('id', v_id, 'code', v_code);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_partner_status(
  p_admin_id uuid, p_agent_id uuid, p_status text, p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin  public.admin_users%ROWTYPE;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_old    text;
BEGIN
  PERFORM public.moderation_assert_trusted();
  v_admin := public.moderation_require_admin(p_admin_id);
  IF v_admin.role NOT IN ('senior_admin', 'super_admin') THEN
    RAISE EXCEPTION 'HELP24_PARTNER_FORBIDDEN: suspending agents needs a senior admin' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('active', 'suspended') THEN
    RAISE EXCEPTION 'HELP24_PARTNER_INVALID: unknown status' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_reason) < 5 OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'HELP24_PARTNER_INVALID: give a reason, in 5 to 500 characters' USING ERRCODE = '22023';
  END IF;
  SELECT status INTO v_old FROM public.partner_agents WHERE id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_PARTNER_NOT_FOUND: no such agent' USING ERRCODE = '22023';
  END IF;
  IF v_old = p_status THEN
    RETURN jsonb_build_object('status', p_status, 'changed', false);
  END IF;
  UPDATE public.partner_agents SET status = p_status WHERE id = p_agent_id;
  INSERT INTO public.partner_admin_events (agent_id, action, reason, admin_id, admin_email, admin_role)
  VALUES (p_agent_id, CASE WHEN p_status = 'suspended' THEN 'suspended' ELSE 'reactivated' END,
          v_reason, v_admin.id, v_admin.email, v_admin.role);
  RETURN jsonb_build_object('status', p_status, 'changed', true);
END;
$$;

-- The token itself never reaches the database: the caller sends its SHA-256.
-- Issuing a new invitation retires every unused older one for that agent.
CREATE OR REPLACE FUNCTION public.admin_issue_partner_invite(
  p_admin_id uuid, p_agent_id uuid, p_token_hash text, p_ttl_hours integer DEFAULT 72
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin   public.admin_users%ROWTYPE;
  v_agent   public.partner_agents%ROWTYPE;
  v_expires timestamptz := now() + make_interval(hours => least(greatest(coalesce(p_ttl_hours, 72), 1), 168));
BEGIN
  PERFORM public.moderation_assert_trusted();
  v_admin := public.moderation_require_admin(p_admin_id);
  IF v_admin.role NOT IN ('senior_admin', 'super_admin') THEN
    RAISE EXCEPTION 'HELP24_PARTNER_FORBIDDEN: inviting agents needs a senior admin' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_agent FROM public.partner_agents WHERE id = p_agent_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_PARTNER_NOT_FOUND: no such agent' USING ERRCODE = '22023';
  END IF;
  IF v_agent.status <> 'active' THEN
    RAISE EXCEPTION 'HELP24_PARTNER_INVALID: reactivate the agent before inviting them' USING ERRCODE = '22023';
  END IF;
  IF v_agent.email IS NULL THEN
    RAISE EXCEPTION 'HELP24_PARTNER_INVALID: add the agent''s email first — it is their sign-in' USING ERRCODE = '22023';
  END IF;

  UPDATE public.partner_invites SET expires_at = now()
   WHERE agent_id = p_agent_id AND used_at IS NULL AND expires_at > now();
  INSERT INTO public.partner_invites (agent_id, token_hash, expires_at, created_by)
  VALUES (p_agent_id, p_token_hash, v_expires, v_admin.id);
  INSERT INTO public.partner_admin_events (agent_id, action, admin_id, admin_email, admin_role)
  VALUES (p_agent_id, 'invite_issued', v_admin.id, v_admin.email, v_admin.role);
  RETURN jsonb_build_object('expires_at', v_expires);
END;
$$;

-- Spends the invitation and links the new login. One login per agent: a new
-- invitation accepted later replaces the old link (how access is reset).
CREATE OR REPLACE FUNCTION public.partner_accept_invite(p_token_hash text, p_auth_subject uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_inv    public.partner_invites%ROWTYPE;
  v_agent  public.partner_agents%ROWTYPE;
BEGIN
  PERFORM public.moderation_assert_trusted();
  SELECT * INTO v_inv FROM public.partner_invites WHERE token_hash = p_token_hash FOR UPDATE;
  IF NOT FOUND OR v_inv.used_at IS NOT NULL OR v_inv.expires_at <= now() THEN
    RAISE EXCEPTION 'HELP24_PARTNER_INVITE_INVALID: this invitation has expired or was already used — ask Help24 for a new one'
      USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_agent FROM public.partner_agents WHERE id = v_inv.agent_id;
  IF v_agent.status <> 'active' THEN
    RAISE EXCEPTION 'HELP24_PARTNER_INVITE_INVALID: this agent account is not active' USING ERRCODE = '22023';
  END IF;

  UPDATE public.partner_invites SET used_at = now() WHERE id = v_inv.id;
  DELETE FROM public.partner_logins WHERE agent_id = v_agent.id;
  INSERT INTO public.partner_logins (auth_subject, agent_id) VALUES (p_auth_subject, v_agent.id);
  INSERT INTO public.partner_admin_events (agent_id, action) VALUES (v_agent.id, 'login_linked');
  RETURN jsonb_build_object('agent_id', v_agent.id, 'email', v_agent.email);
END;
$$;

-- Peek at an invitation without spending it: what the acceptance page shows.
CREATE OR REPLACE FUNCTION public.partner_invite_preview(p_token_hash text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN i.id IS NULL OR i.used_at IS NOT NULL OR i.expires_at <= now() OR g.status <> 'active'
    THEN jsonb_build_object('valid', false)
    ELSE jsonb_build_object('valid', true, 'email', g.email, 'name', g.display_name, 'expires_at', i.expires_at)
  END
  FROM (SELECT 1) one
  LEFT JOIN public.partner_invites i ON i.token_hash = p_token_hash
  LEFT JOIN public.partner_agents g ON g.id = i.agent_id;
$$;

-- ── Grants: nothing here is for the app or the public key ───────────────────
ALTER TABLE public.member_active_days   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partner_logins       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partner_invites      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partner_admin_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.member_active_days, public.partner_logins, public.partner_invites,
  public.partner_admin_events, public.partner_member_progress
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.member_active_days, public.partner_logins, public.partner_invites,
  public.partner_admin_events, public.partner_member_progress TO service_role;

REVOKE ALL ON FUNCTION public.fn_member_active_day() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_create_partner_agent(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_set_partner_status(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_issue_partner_invite(uuid, uuid, text, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.partner_accept_invite(text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.partner_invite_preview(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_partner_agent(uuid, text, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_partner_status(uuid, uuid, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_issue_partner_invite(uuid, uuid, text, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.partner_accept_invite(text, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.partner_invite_preview(text) TO service_role;

COMMIT;
