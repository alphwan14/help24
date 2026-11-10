-- =============================================================================
-- Migration 139: Materials Advance (part of a big job paid to the fundi early)
-- =============================================================================
-- ADDITIVE. One new table, nothing written at apply time.
--
-- On a job of KES 10,000 or more with a verified provider, the customer may pay
-- with Materials Advance: they pay the whole job once (plus the usual payment
-- protection fee), and when the fundi is ready to buy materials the customer
-- taps "Send materials money". Help24 then pays 40% of the job to the fundi and
-- keeps holding the rest until the job is approved. Owner decisions 2026-11-10:
-- the customer releases it (never automatic), verified providers only, and if
-- the job fails the customer gets back everything still held, fee included.
--
-- One row per transaction. The row is the advance's own payout record: it has
-- its own status and its own M-Pesa conversation ids, because a transaction's
-- columns describe exactly one payout (the final one) and the B2C callback finds
-- a payout by its ConversationID.
--
-- Status:
--   held       paid for, not sent. Releasable only while the transaction is 'paid'.
--   sending    the customer's release claimed it; B2C requested or in flight.
--   paid_out   M-Pesa confirmed the advance reached the fundi. Final payout and
--              every dispute decision subtract `amount` from what is held.
--   cancelled  never sent: the job was approved (the full amount goes in the
--              final payout), or the payment never completed.
--   frozen     never sent: a dispute opened first. The ruling covers the full amount.
-- Every transition is a conditional UPDATE on `status` (compare-and-set), so of
-- a release, an approval and a dispute arriving together exactly one wins.
--
-- Service role only (the backend). No policies: anon and authenticated get
-- nothing; the app reads the advance through GET /jobs/:id/lifecycle.
--
-- Deploy order: apply this BEFORE the backend that reads it. The backend treats
-- a missing table as "no advances" (it cannot hold any), and every other read
-- error as a refusal, so a payout never guesses.
--
-- Rollback (only while no row exists): DROP TABLE IF EXISTS public.materials_advances;
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.materials_advances (
  id                         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id             uuid        NOT NULL UNIQUE REFERENCES public.transactions(id) ON DELETE RESTRICT,
  post_id                    uuid        NOT NULL,
  client_user_id             text        NOT NULL,
  provider_user_id           text        NOT NULL,
  -- Whole KES, at most 40% of the job (backend/src/mpesa/advance.ts).
  amount                     integer     NOT NULL CHECK (amount > 0),
  status                     text        NOT NULL DEFAULT 'held'
                                         CHECK (status IN ('held', 'sending', 'paid_out', 'cancelled', 'frozen')),
  -- The B2C payout of the advance (how its callback finds this row).
  conversation_id            text        UNIQUE,
  originator_conversation_id text        UNIQUE,
  payout_destination_id      uuid,
  failure_reason             text,
  release_requested_at       timestamptz,
  paid_out_at                timestamptz,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS materials_advances_post_idx ON public.materials_advances (post_id);
-- The stuck-advance alert reads only advances in flight.
CREATE INDEX IF NOT EXISTS materials_advances_sending_idx
  ON public.materials_advances (release_requested_at) WHERE status = 'sending';

CREATE OR REPLACE FUNCTION public.materials_advances_touch()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS materials_advances_touch ON public.materials_advances;
CREATE TRIGGER materials_advances_touch
  BEFORE UPDATE ON public.materials_advances
  FOR EACH ROW EXECUTE FUNCTION public.materials_advances_touch();

ALTER TABLE public.materials_advances ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.materials_advances FROM anon, authenticated;
