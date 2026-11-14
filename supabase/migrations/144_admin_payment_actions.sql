-- =============================================================================
-- Migration 144: admin actions on a payment
-- =============================================================================
-- Two widened CHECKs and one nullable column. No rows change.
--
-- The dashboard's Payments page now opens each payment with its whole story
-- and lets an admin act on it (backend admin/payments). Every action is
-- recorded in admin_finance_actions (migration 117: append-only, the admin's
-- name and role, a required reason, the state before) BEFORE it takes effect:
--
--   payout_retried         send the provider's M-Pesa payout again (it failed,
--                          or the job was approved and nothing went out)
--   payout_status_checked  ask M-Pesa what happened to a payout with no answer
--   completion_approved    approve finished work the client left waiting
--   dispute_opened         open a dispute for the client or the provider
--   hire_cancelled         undo a hire that was never paid for
--
-- job_completions.approved_by gains 'admin' (approved by Help24 staff), and
-- disputes.opened_by_admin_id records an admin who opened a case for a party.
--
-- Rollback (only while no row uses the new values):
--   ALTER TABLE public.disputes DROP COLUMN IF EXISTS opened_by_admin_id;
--   ALTER TABLE public.job_completions DROP CONSTRAINT job_completions_approved_by_check;
--   ALTER TABLE public.job_completions ADD CONSTRAINT job_completions_approved_by_check
--     CHECK (approved_by IS NULL OR approved_by IN ('client', 'system'));
--   ALTER TABLE public.admin_finance_actions DROP CONSTRAINT admin_finance_actions_action_type_check;
--   ALTER TABLE public.admin_finance_actions ADD CONSTRAINT admin_finance_actions_action_type_check
--     CHECK (action_type IN ('manual_settlement_recorded', 'ruling_applied'));
-- =============================================================================

ALTER TABLE public.admin_finance_actions DROP CONSTRAINT IF EXISTS admin_finance_actions_action_type_check;
ALTER TABLE public.admin_finance_actions ADD CONSTRAINT admin_finance_actions_action_type_check
  CHECK (action_type IN (
    'manual_settlement_recorded',
    'ruling_applied',
    'payout_retried',
    'payout_status_checked',
    'completion_approved',
    'dispute_opened',
    'hire_cancelled'
  ));

ALTER TABLE public.job_completions DROP CONSTRAINT IF EXISTS job_completions_approved_by_check;
ALTER TABLE public.job_completions ADD CONSTRAINT job_completions_approved_by_check
  CHECK (approved_by IS NULL OR approved_by IN ('client', 'system', 'admin'));

ALTER TABLE public.disputes
  ADD COLUMN IF NOT EXISTS opened_by_admin_id uuid REFERENCES public.admin_users (id) ON DELETE SET NULL;

COMMENT ON COLUMN public.disputes.opened_by_admin_id IS
  'The admin who opened this case for the client or provider (migration 144); null when a party opened it.';
