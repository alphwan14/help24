-- =============================================================================
-- Migration 106 — trust and preference transitions (Phase 1: functions only)
-- =============================================================================
-- NOT APPLIED. Creates three functions; touches no row.
--
-- WHY THESE ARE DATABASE FUNCTIONS AND NOT SERVICE CODE
-- -----------------------------------------------------
-- Each is a multi-step state change that must happen completely or not at all.
-- Split across PostgREST calls they become separate transactions, and every gap
-- is a real failure mode: a crash mid-way leaves a provider with no default, or
-- two, or a spent OTP that verified nothing. One function is one transaction,
-- and the partial unique indexes become a backstop rather than the only defence.
--
-- The backend still owns the OTP: these take a HASH, never a code. The pepper
-- lives in the backend, so a database disclosure yields no usable code and no
-- way to compute one. The database enforces atomicity and single use; the
-- backend owns the secret. Neither alone is sufficient — that is the intent.
--
-- Rollback:
--   DROP FUNCTION IF EXISTS public.fn_consume_payout_verification(uuid, text, boolean);
--   DROP FUNCTION IF EXISTS public.fn_set_default_payout_destination(uuid, text);
--   DROP FUNCTION IF EXISTS public.fn_retire_payout_destination(uuid, text, text);
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Consume an OTP challenge; on success activate the destination.
-- ---------------------------------------------------------------------------
-- outcome: verified | invalid_code | expired | already_used | too_many_tries | not_found
--
-- NOTE THE CHANGE FROM THE FIRST DRAFT: verifying a new destination no longer
-- RETIRES the previous one. Retirement destroys a capability; the provider only
-- expressed a preference. The old destination stays `active` — still usable,
-- still auditable — and merely stops being the default. Retiring is now an
-- explicit act with its own function and its own recorded reason.

CREATE OR REPLACE FUNCTION public.fn_consume_payout_verification(
  p_verification_id uuid,
  p_code_hash       text,
  p_make_default    boolean DEFAULT true
)
RETURNS TABLE (outcome text, destination_id uuid, attempts_remaining int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v public.payout_destination_verifications%ROWTYPE;
  d public.payout_destinations%ROWTYPE;
BEGIN
  -- FOR UPDATE serialises concurrent attempts on one challenge. Without it two
  -- requests read attempts=4 together and both write 5 — a free extra guess per
  -- racing pair.
  SELECT * INTO v FROM public.payout_destination_verifications
   WHERE id = p_verification_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, 0; RETURN;
  END IF;
  IF v.consumed_at IS NOT NULL THEN
    RETURN QUERY SELECT 'already_used'::text, v.destination_id, 0; RETURN;
  END IF;
  IF v.failed_at IS NOT NULL THEN
    RETURN QUERY SELECT 'too_many_tries'::text, v.destination_id, 0; RETURN;
  END IF;
  IF v.expires_at <= now() THEN
    UPDATE public.payout_destination_verifications
       SET failed_at = now(), failed_reason = 'expired' WHERE id = v.id;
    RETURN QUERY SELECT 'expired'::text, v.destination_id, 0; RETURN;
  END IF;

  IF v.code_hash IS DISTINCT FROM p_code_hash THEN
    UPDATE public.payout_destination_verifications
       SET attempts       = attempts + 1,
           failed_at      = CASE WHEN attempts + 1 >= max_attempts THEN now() END,
           failed_reason  = CASE WHEN attempts + 1 >= max_attempts THEN 'too_many_attempts' END
     WHERE id = v.id RETURNING * INTO v;

    IF v.failed_at IS NOT NULL THEN
      RETURN QUERY SELECT 'too_many_tries'::text, v.destination_id, 0;
    ELSE
      RETURN QUERY SELECT 'invalid_code'::text, v.destination_id, (v.max_attempts - v.attempts)::int;
    END IF;
    RETURN;
  END IF;

  -- Correct. Everything below is one atomic unit.
  SELECT * INTO d FROM public.payout_destinations WHERE id = v.destination_id FOR UPDATE;

  IF d.status = 'retired' THEN
    -- Retired while the code was in flight. Refuse rather than revive: the
    -- append-only trigger would refuse anyway, and reviving is how money
    -- reaches an abandoned number.
    UPDATE public.payout_destination_verifications
       SET failed_at = now(), failed_reason = 'destination_retired' WHERE id = v.id;
    RETURN QUERY SELECT 'not_found'::text, d.id, 0; RETURN;
  END IF;

  -- Spend the challenge FIRST. If anything below fails the whole transaction
  -- rolls back, so a code is never both spent and unused.
  UPDATE public.payout_destination_verifications SET consumed_at = now() WHERE id = v.id;

  UPDATE public.payout_destinations
     SET status              = 'active',
         verified_at         = now(),
         verification_method = 'otp',
         verified_by         = 'system',
         verification_id     = v.id
   WHERE id = d.id;

  IF p_make_default THEN
    -- Demote the incumbent in the SAME transaction as the promotion, so the
    -- one-default index never sees two.
    UPDATE public.payout_destinations
       SET is_default = false
     WHERE provider_user_id = d.provider_user_id AND is_default AND id <> d.id;
    UPDATE public.payout_destinations SET is_default = true WHERE id = d.id;
  END IF;

  RETURN QUERY SELECT 'verified'::text, d.id, 0;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_consume_payout_verification(uuid, text, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_consume_payout_verification(uuid, text, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- Move the default between two ALREADY-TRUSTED destinations.
-- ---------------------------------------------------------------------------
-- Separate from verification because choosing between destinations you have
-- already proven is a preference, not a trust decision, and should not require
-- another OTP. It cannot elevate anything: only an `active` row can be made
-- default, and this function cannot make a row active.

CREATE OR REPLACE FUNCTION public.fn_set_default_payout_destination(
  p_destination_id uuid,
  p_actor          text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE d public.payout_destinations%ROWTYPE;
BEGIN
  SELECT * INTO d FROM public.payout_destinations WHERE id = p_destination_id FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  IF d.status <> 'active' THEN
    RAISE EXCEPTION 'help24_payout_default_requires_active'
      USING ERRCODE = '22023',
            HINT = 'Verify the destination before making it the default.';
  END IF;

  UPDATE public.payout_destinations
     SET is_default = false
   WHERE provider_user_id = d.provider_user_id AND is_default AND id <> d.id;

  UPDATE public.payout_destinations
     SET is_default = true,
         metadata   = metadata || jsonb_build_object('default_set_by', p_actor, 'default_set_at', now())
   WHERE id = d.id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_set_default_payout_destination(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_set_default_payout_destination(uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- Retire a destination.
-- ---------------------------------------------------------------------------
-- Deliberately does NOT auto-promote another active destination to default.
-- Silently choosing where someone's money goes is the behaviour this entire
-- design exists to remove. If the retired row was the default, the provider is
-- left with none and must choose — and until they do, new escrows refuse with a
-- clear message. Escrows already funded are unaffected: they carry a snapshot.

CREATE OR REPLACE FUNCTION public.fn_retire_payout_destination(
  p_destination_id uuid,
  p_reason         text,
  p_actor          text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE affected int;
BEGIN
  IF btrim(coalesce(p_reason, '')) = '' THEN
    RAISE EXCEPTION 'help24_payout_retire_reason_required'
      USING ERRCODE = '22023',
            HINT = 'An unexplained retirement cannot be told apart from an attack.';
  END IF;

  -- is_default is cleared by the append-only trigger on the way through.
  UPDATE public.payout_destinations
     SET status         = 'retired',
         retired_at     = now(),
         retired_reason = left(p_reason, 200),
         metadata       = metadata || jsonb_build_object('retired_by', p_actor)
   WHERE id = p_destination_id
     AND status <> 'retired';

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_retire_payout_destination(uuid, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_retire_payout_destination(uuid, text, text) TO service_role;
