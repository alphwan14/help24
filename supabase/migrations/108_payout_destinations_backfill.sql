-- =============================================================================
-- Migration 108 — backfill destinations from users.phone_number (Phase 1: DATA)
-- =============================================================================
-- ⚠️ THE ONLY MIGRATION IN THIS SET THAT WRITES ROWS. NOT APPLIED.
--
-- Measured against production 2026-08-07:
--   users total ............................ 15
--   users with a non-empty phone_number ..... 5
--   rows this INSERTS ....................... 5
--   unparseable numbers skipped ............. 0
--   existing rows UPDATED ................... 0   ← it only inserts
--   existing rows DELETED ................... 0
--
-- REGENERATED for the provenance model. The previous version created rows with
-- `status='legacy'` — a lifecycle state invented to mean "usable but unproven".
-- That conflated two questions and could not distinguish an admin-asserted
-- destination from an OTP-proven one. Now:
--
--   status              = 'active'      — it IS usable; that is a fact
--   is_default          = true          — it is the automatic choice
--   verification_method = 'migration'   — and NOBODY proved control of it
--
-- Nothing is hidden by this. `migration` is a first-class, permanent statement
-- that these numbers arrived from a profile field and were never verified by
-- anyone. Every payout made against one carries that word in its escrow
-- snapshot, forever. Phase 5 refuses methods outside ('otp','future_kyc'),
-- which is what finally retires this provenance rather than papering over it.
--
-- WHY `is_default = true` IS SAFE HERE
-- ------------------------------------
-- Each backfilled provider gets exactly one destination, so the default is not
-- a choice being made on their behalf — it is the only option, and it is the
-- number they are already being paid on today. The one-default index makes a
-- second one impossible; the NOT EXISTS guard makes a re-run a no-op.
--
-- ONE MSISDN IS SHARED BY TWO ACCOUNTS (both the operator's). Accepted
-- deliberately: `payout_destinations_normalized_idx` is not unique, because a
-- Kenyan household or micro-business genuinely shares one M-Pesa line. Shared
-- numbers are detectable by query for review; they are not blocked.
--
-- NO BEHAVIOUR CHANGE ON ITS OWN: nothing reads these rows until
-- PAYOUT_DESTINATIONS_ENABLED is switched on.
--
-- Rollback — removes ONLY rows this created, identified by provenance:
--   ALTER TABLE public.payout_destinations DISABLE TRIGGER trg_payout_destinations_append_only;
--   DELETE FROM public.payout_destinations
--    WHERE verification_method = 'migration'
--      AND metadata ->> 'provenance' = 'migration_108';
--   ALTER TABLE public.payout_destinations ENABLE TRIGGER trg_payout_destinations_append_only;
--   -- The trigger toggle is required because the table refuses DELETE by design.
--   -- Only safe while nothing references the rows:
--   --   SELECT count(*) FROM public.escrow       WHERE payout_destination_id IS NOT NULL;
--   --   SELECT count(*) FROM public.transactions WHERE payout_destination_id IS NOT NULL;
--   -- Both must be 0, or the FK will (correctly) refuse.
-- =============================================================================

INSERT INTO public.payout_destinations (
  provider_user_id,
  channel,
  country,
  destination_value,
  normalized_destination,
  status,
  is_default,
  verification_method,
  verified_at,
  verified_by,
  created_by_uid,
  metadata
)
SELECT
  u.id,
  'mpesa',
  'KE',               -- every existing number is a Kenyan MSISDN by construction
  u.phone_number,
  n.msisdn,
  'active',
  true,
  'migration',        -- nobody proved control of this number
  now(),              -- when it was admitted, NOT when anyone verified it
  'migration_108',
  u.id,
  jsonb_build_object(
    'provenance',    'migration_108',
    'source_column', 'users.phone_number',
    'captured_at',   now()
  )
FROM public.users u
CROSS JOIN LATERAL (
  -- STRIP EXACTLY WHAT THE RUNTIME STRIPS: whitespace, dash, brackets, plus.
  -- NOT `[^0-9]`. An earlier draft stripped every non-digit, which is MORE
  -- permissive than `normalizeMsisdn` — it would have accepted "254712345678x"
  -- that the payment path rejects, backfilling a destination that can never be
  -- paid.
  SELECT regexp_replace(coalesce(u.phone_number, ''), '[[:space:]\-()+]', '', 'g') AS stripped
) s
CROSS JOIN LATERAL (
  -- MIRRORS backend/src/common/phone/msisdn.ts EXACTLY: same two rewrites, same
  -- accept pattern. If these ever disagree a provider is matched at one
  -- canonical form and PAID at another. Change both or neither.
  SELECT CASE
    WHEN s.stripped ~ '^0\d{9}$' THEN '254' || substring(s.stripped from 2)
    WHEN s.stripped ~ '^7\d{8}$' THEN '254' || s.stripped
    ELSE s.stripped
  END AS candidate
) c
CROSS JOIN LATERAL (
  SELECT CASE WHEN c.candidate ~ '^254\d{9}$' THEN c.candidate ELSE NULL END AS msisdn
) n
WHERE n.msisdn IS NOT NULL
  -- Never create a second destination for anyone who already has one, so a
  -- re-run after partial failure is a no-op rather than a duplicate.
  AND NOT EXISTS (
    SELECT 1 FROM public.payout_destinations d
     WHERE d.provider_user_id = u.id
       AND d.channel = 'mpesa'
       AND d.status <> 'retired'
  );

-- Post-conditions the operator should see:
--
--   SELECT status, verification_method, count(*), count(*) FILTER (WHERE is_default)
--     FROM public.payout_destinations GROUP BY 1, 2;
--   -- expect: active | migration | 5 | 5
--
--   SELECT count(*) FROM public.payout_destinations WHERE verification_method = 'otp';
--   -- expect: 0 — this migration proves nothing and must not claim to
