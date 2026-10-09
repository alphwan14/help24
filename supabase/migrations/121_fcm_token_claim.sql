-- 121 — A device's push token belongs to whoever is signed in on it now.
--
-- THE BUG (found 2026-10-09 on the A21s, production)
-- `fcm_tokens.token` is UNIQUE, and the app registers its token with
-- `upsert(onConflict: token)`. When account B signs in on a phone where account
-- A was signed in, the phone's token row still belongs to A — sign-out only
-- removes it when the app happens to hold the token in memory, which it does
-- not after an offline launch, and never when the phone was offline at
-- sign-out. B's upsert therefore becomes an UPDATE of A's row, and
-- `fcm_tokens_owner_all` (USING user_id = jwt user_id) refuses it:
--   42501 new row violates row-level security policy (USING expression)
-- Result: B receives no pushes on that phone, and A — signed out — still does.
--
-- WHY A FUNCTION, NOT A WIDER POLICY
-- RLS cannot tell "the device that holds this token" from "any other user":
-- loosening the UPDATE policy would let any signed-in user rewrite any token
-- row. This function does exactly one thing — assign ONE token, which the
-- caller presents, to the CALLER (from the verified JWT, never a parameter) —
-- and nothing else. The table's policies are untouched; the app keeps its
-- direct DELETE of its own rows.
--
-- Who can know a token: only the device it was issued to and the server.
-- `authenticated` reads only its own rows (fcm_tokens_owner_all) and `anon`
-- has no table privileges, so no client can learn another account's token to
-- claim it. This is the usual rule for push tokens: last sign-in on the device
-- wins.
--
-- APPLY: safe at any time; additive. Builds up to 1.0.2 keep using the direct
-- upsert (unchanged behaviour); 1.0.3+ call this and fall back to the upsert
-- if it is missing. Idempotent. No data is rewritten by applying it — a stale
-- row is reassigned only when its device's new account next registers.
--
-- ROLLBACK:
--   drop function if exists public.register_fcm_token(text, text);

CREATE OR REPLACE FUNCTION public.register_fcm_token(p_token text, p_platform text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid text := auth.jwt() ->> 'user_id';
  v_token text := btrim(coalesce(p_token, ''));
  v_platform text := coalesce(nullif(btrim(coalesce(p_platform, '')), ''), 'android');
BEGIN
  IF v_uid IS NULL OR v_uid = '' THEN
    RAISE EXCEPTION 'register_fcm_token: not signed in' USING ERRCODE = '42501';
  END IF;
  IF v_token = '' OR length(v_token) > 4096 THEN
    RAISE EXCEPTION 'register_fcm_token: invalid token' USING ERRCODE = '22023';
  END IF;
  IF v_platform NOT IN ('android', 'ios', 'web') THEN
    RAISE EXCEPTION 'register_fcm_token: invalid platform' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.fcm_tokens (user_id, token, platform, updated_at)
  VALUES (v_uid, v_token, v_platform, now())
  ON CONFLICT (token) DO UPDATE
    SET user_id    = EXCLUDED.user_id,
        platform   = EXCLUDED.platform,
        updated_at = now();
END;
$$;

COMMENT ON FUNCTION public.register_fcm_token(text, text) IS
  'Assigns this device''s FCM token to the signed-in caller (jwt user_id). Last sign-in on a device wins. See migration 121.';

REVOKE ALL ON FUNCTION public.register_fcm_token(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.register_fcm_token(text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.register_fcm_token(text, text) TO authenticated;
