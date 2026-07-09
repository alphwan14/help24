-- =============================================================================
-- Migration 060: Lock financial tables to the backend (service_role) only  [S2]
-- =============================================================================
-- SECURITY FIX. The base schema ran `GRANT ALL ON ALL TABLES IN SCHEMA public
-- TO anon, authenticated`, and every RLS policy is `USING (true)`. Combined with
-- the PUBLIC anon/publishable key, that let ANY client read AND write the money
-- tables directly (e.g. UPDATE escrow SET status='released' with no payout).
--
-- This migration REVOKES anon/authenticated access to the financial tables so
-- they can only be reached by the backend (service_role). It does NOT touch data
-- and does NOT change service_role access (the backend keeps working).
--
-- ⚠️ ORDERING — APPLY ONLY AFTER the app that reads these tables directly is
-- deployed. The mobile client has been updated to read payment/escrow state via
-- the backend (GET /mpesa/status/:postId) instead of Supabase directly. If any
-- still-installed old client reads transactions/escrow directly, it will get
-- "permission denied (42501)" until updated.
--
-- Rollback (re-open — NOT recommended):
--   GRANT SELECT ON public.transactions, public.escrow TO anon, authenticated; ...
-- =============================================================================

-- 1. Remove all client (anon + authenticated) privileges on the money tables.
REVOKE ALL ON public.transactions      FROM anon, authenticated;
REVOKE ALL ON public.escrow            FROM anon, authenticated;
REVOKE ALL ON public.disputes          FROM anon, authenticated;
REVOKE ALL ON public.dispute_decisions FROM anon, authenticated;
REVOKE ALL ON public.job_completions   FROM anon, authenticated;
REVOKE ALL ON public.settlements       FROM anon, authenticated;

-- 2. Defense in depth: pin the RLS policies to service_role so that even if a
--    grant is accidentally re-added later, the client still cannot pass RLS.
--    (The originals had no TO clause, so they applied to PUBLIC.)
DO $$
BEGIN
  -- transactions
  DROP POLICY IF EXISTS transactions_service_role ON public.transactions;
  CREATE POLICY transactions_service_role ON public.transactions
    AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

  -- escrow
  DROP POLICY IF EXISTS escrow_service_role ON public.escrow;
  CREATE POLICY escrow_service_role ON public.escrow
    AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

  -- disputes
  DROP POLICY IF EXISTS disputes_service_role ON public.disputes;
  CREATE POLICY disputes_service_role ON public.disputes
    AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

  -- job_completions
  DROP POLICY IF EXISTS job_completions_service_role ON public.job_completions;
  CREATE POLICY job_completions_service_role ON public.job_completions
    AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);
END $$;

-- NOTE: dispute_decisions (049) and settlements (058) already define
-- service_role-scoped policies; the REVOKE above closes their grant exposure.
--
-- The REVOKE (step 1) is the essential lock and is fully reversible. Step 2 is
-- defense in depth: because service_role BYPASSES RLS in Supabase, a policy that
-- was `USING (true)` with no TO clause actually granted anon/authenticated — so
-- pinning it TO service_role means even a re-added grant can't pass RLS.
