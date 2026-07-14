-- =============================================================================
-- Migration 075 — reputation recompute on post status change
-- =============================================================================
-- Closes the drift found in the profile audit: completion_rate / dispute_rate
-- in provider_reputation use posts with status IN ('completed','cancelled') as
-- their denominator, but recompute only fired on review submit, job approval,
-- and dispute resolution — NEVER on post cancellation. A cancelled job changed
-- a provider's true rates without the stored rates moving until the next
-- unrelated event.
--
-- Fix: a DB trigger recomputes the affected provider(s) whenever a post's
-- status or selected provider changes, regardless of which writer (app,
-- backend, admin) made the change. fn_recompute_provider_reputation (055) is
-- idempotent — extra fires are harmless.
--
-- SECURITY DEFINER so the recompute can write the service_role-only
-- provider_reputation table even when the updater is a client role.
--
-- SAFE + ADDITIVE. Rollback:
--   DROP TRIGGER posts_reputation_recompute ON public.posts;
--   DROP FUNCTION public.trg_posts_reputation_recompute();
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trg_posts_reputation_recompute()
RETURNS TRIGGER AS $$
BEGIN
  -- Only the concluded states ('completed','cancelled') and the provider
  -- assignment feed the rate math — skip unrelated transitions.
  IF NEW.selected_provider_id IS NOT NULL
     AND (
       (OLD.status IS DISTINCT FROM NEW.status
        AND (OLD.status IN ('completed','cancelled') OR NEW.status IN ('completed','cancelled')))
       OR OLD.selected_provider_id IS DISTINCT FROM NEW.selected_provider_id
     ) THEN
    PERFORM public.fn_recompute_provider_reputation(NEW.selected_provider_id);
  END IF;
  -- Provider reassigned away: the OLD provider's denominators change too.
  IF OLD.selected_provider_id IS NOT NULL
     AND OLD.selected_provider_id IS DISTINCT FROM NEW.selected_provider_id THEN
    PERFORM public.fn_recompute_provider_reputation(OLD.selected_provider_id);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS posts_reputation_recompute ON public.posts;
CREATE TRIGGER posts_reputation_recompute
  AFTER UPDATE OF status, selected_provider_id ON public.posts
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_posts_reputation_recompute();

-- One-time repair: recompute every provider that has ever been assigned, so
-- rates that drifted before this trigger existed are corrected now.
DO $$
DECLARE p TEXT;
BEGIN
  FOR p IN
    SELECT DISTINCT selected_provider_id
    FROM public.posts
    WHERE selected_provider_id IS NOT NULL
  LOOP
    PERFORM public.fn_recompute_provider_reputation(p);
  END LOOP;
END $$;
