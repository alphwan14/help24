-- Persist Daraja's OriginatorConversationID for each B2C payout.
--
-- Why: the B2C RESULT callback is the only signal that moves a payout from
-- 'payout_pending' to 'released'. When that callback never arrives, the only way
-- to learn the real outcome is Daraja's Transaction Status Query API, which
-- correlates by TransactionID (the M-Pesa receipt, which we only get FROM the
-- missing callback) or by OriginatorConversationID. We already receive the
-- OriginatorConversationID in the B2C initiation response, so storing it lets the
-- admin reconcile path query Daraja for genuinely stranded payouts.
--
-- Idempotent + non-destructive: adds a nullable column only. Existing rows keep
-- NULL and are reconcilable via conversation_id / dev simulation.
ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS originator_conversation_id TEXT;

CREATE INDEX IF NOT EXISTS idx_transactions_originator_conversation_id
  ON public.transactions (originator_conversation_id);
