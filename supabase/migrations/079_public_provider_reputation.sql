-- =============================================================================
-- Migration 079: public_provider_reputation view (batched feed reputation)
-- =============================================================================
-- Feed cards currently make one backend round-trip per distinct author
-- (GET /reputation/:id) AFTER the card has painted, so ratings "pop in".
-- This view lets the app fetch every visible author's reputation in ONE
-- Supabase query alongside the feed and render complete cards on first paint.
--
-- The view mirrors the GET /reputation/:providerId response shape EXACTLY
-- (field names + 1-dp rounding), so the client parses rows with the same
-- ProviderReputation.fromJson used for the backend endpoint. The endpoint
-- remains the fallback path — providers with no provider_reputation row yet
-- are absent here, and the per-card backend fetch still lazily backfills them.
--
-- Exposes nothing new: every column is already public via the unauthenticated
-- backend endpoint. Runs with the view owner's rights (NOT security_invoker),
-- same pattern as 062_public_profiles_view, so anon/authenticated can read it
-- while provider_reputation itself stays service-role-only.
--
-- SAFE + ADDITIVE: creates a read-only view; changes no data, revokes nothing.
-- Rollback: DROP VIEW public.public_provider_reputation;
-- =============================================================================

CREATE OR REPLACE VIEW public.public_provider_reputation AS
SELECT
  pr.provider_id,
  ROUND(pr.avg_rating::numeric, 1)::double precision      AS average_rating,
  ROUND(pr.bayesian_rating::numeric, 1)::double precision AS bayesian_rating,
  pr.total_reviews,
  pr.completed_jobs,
  pr.disputed_jobs,
  pr.open_disputes,
  pr.completion_rate,
  pr.dispute_rate,
  pr.repeat_clients,
  pr.tier,
  u.created_at AS member_since,
  pr.last_active_at
FROM public.provider_reputation pr
JOIN public.users u ON u.id = pr.provider_id;

GRANT SELECT ON public.public_provider_reputation TO anon, authenticated;
