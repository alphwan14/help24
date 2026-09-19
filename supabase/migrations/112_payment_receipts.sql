-- 112 — Help24 platform receipts.
--
-- WHY THIS EXISTS
-- Help24 has no receipt identifier of its own. `transactions.mpesa_receipt` is
-- Safaricom's receipt for the customer→Help24 leg; it is issued by Daraja, is
-- absent until the STK callback lands, is absent entirely for a failed payment,
-- and would be wrong to present as "the Help24 receipt number". This table gives
-- every transaction that actually moved money ONE stable Help24 document number.
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   * It does not duplicate amounts, fees or status. Those live on `transactions`
--     (write-once) and the live settlement state is derived at read time by
--     backend/src/jobs/settlement-state.ts — the ONE canonical money state
--     machine. A receipt that cached a status would go stale the moment a payout
--     or refund landed, and would become a second, competing source of truth.
--   * It does not participate in the payment state machine. Nothing in
--     mpesa.service.ts, the escrow flow or the dispute flow reads or writes this
--     table. Rows are allocated lazily by the Service Records reader.
--
-- IDEMPOTENCY IS THE SCHEMA, NOT THE CODE (Phase 11)
-- `transaction_id` is UNIQUE. A retried request, a double-tap or two concurrent
-- readers cannot mint a second receipt for the same payment — the second insert
-- loses to the constraint and the existing row is returned.

BEGIN;

-- ── Receipt number sequence ──────────────────────────────────────────────────
-- A sequence is race-free by construction, which is the whole point: two
-- concurrent allocations can never be handed the same number. Numbers are
-- monotonic and never reused. They are NOT gapless — a rolled-back insert burns
-- a value — and that is fine: a receipt number must be unique and stable, not
-- consecutive.
CREATE SEQUENCE IF NOT EXISTS public.help24_receipt_seq AS bigint START WITH 1;

COMMENT ON SEQUENCE public.help24_receipt_seq IS
  'Allocator for payment_receipts.receipt_number. Monotonic, may contain gaps.';

-- The backend connects as `service_role`, and INSERT permission on the table is
-- NOT enough: the receipt_number DEFAULT calls nextval() on this sequence, and
-- nextval needs USAGE on the sequence itself. Without this grant every receipt
-- issuance fails with "permission denied for sequence help24_receipt_seq" —
-- and it fails ONLY against a real database, because the privilege check does
-- not exist in a mock and does not apply to the owner role that runs
-- migrations. No other role is granted anything here: anon and authenticated
-- have no INSERT policy on payment_receipts, so they can never reach nextval.
GRANT USAGE ON SEQUENCE public.help24_receipt_seq TO service_role;

-- ── Receipt number format: HLP-<year>-<6-digit counter> ──────────────────────
-- e.g. HLP-2026-000184. The year is the year of ISSUE. The counter is global
-- rather than per-year, so the number is unique on its own and no second
-- sequence has to be reset on 1 January.
CREATE OR REPLACE FUNCTION public.issue_help24_receipt_number()
RETURNS text
LANGUAGE sql
VOLATILE
SET search_path = public, pg_temp
AS $$
  SELECT 'HLP-'
      || to_char(now() AT TIME ZONE 'UTC', 'YYYY')
      || '-'
      || lpad(nextval('public.help24_receipt_seq')::text, 6, '0');
$$;

COMMENT ON FUNCTION public.issue_help24_receipt_number() IS
  'Returns the next Help24 receipt number, e.g. HLP-2026-000184.';

-- ── The table ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.payment_receipts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- ONE receipt per transaction. This UNIQUE is the idempotency guarantee.
  -- RESTRICT matches escrow/job_completions/disputes, which all already pin
  -- transactions down so a row carrying money cannot be deleted out from under
  -- its dependents.
  transaction_id    uuid NOT NULL UNIQUE
                      REFERENCES public.transactions(id) ON DELETE RESTRICT,

  -- Denormalised for lookup by job. Intentionally carries NO foreign key, which
  -- mirrors transactions.post_id (also unconstrained). Adding one here would
  -- newly block post deletions that succeed today — a behaviour change this
  -- migration has no business making.
  post_id           uuid NOT NULL,

  receipt_number    text NOT NULL UNIQUE
                      DEFAULT public.issue_help24_receipt_number(),

  -- The rail the CUSTOMER paid on. Today every inbound payment is M-Pesa STK.
  -- The CHECK admits airtel_money so that when Airtel is genuinely integrated
  -- its reference flows into this same document with no schema change and no
  -- second receipt model. Nothing fakes an Airtel payment in the meantime.
  payment_method    text NOT NULL DEFAULT 'mpesa'
                      CHECK (payment_method IN ('mpesa', 'airtel_money')),

  issued_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.payment_receipts IS
  'Immutable Help24 platform receipts. One row per transaction that moved money. '
  'Amounts and status are NOT stored here — they are read live from transactions '
  'and derived by deriveSettlementState() so a receipt can never go stale.';

COMMENT ON COLUMN public.payment_receipts.receipt_number IS
  'Stable Help24 document number (HLP-YYYY-NNNNNN). Never derived from, and never '
  'equal to, the M-Pesa/Airtel reference.';

-- Lookup by job — the Service Records reader fetches by post.
CREATE INDEX IF NOT EXISTS idx_payment_receipts_post_id
  ON public.payment_receipts (post_id);

-- Admin listings order newest-first.
CREATE INDEX IF NOT EXISTS idx_payment_receipts_issued_at
  ON public.payment_receipts (issued_at DESC);

-- ── RLS: service role only ───────────────────────────────────────────────────
-- Matches job_completions_service_role and disputes_service_role exactly. The
-- mobile client never reads this table directly; receipts are served by the
-- backend, which applies the same participant check as GET /jobs/:id/lifecycle.
-- Because there is no client-facing INSERT/UPDATE/DELETE policy at all, a user
-- cannot alter a receipt number, an amount or a settlement state from a device —
-- which is Phase 10's immutability requirement enforced by the database rather
-- than by application code.
ALTER TABLE public.payment_receipts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS payment_receipts_service_role ON public.payment_receipts;
CREATE POLICY payment_receipts_service_role
  ON public.payment_receipts
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

COMMIT;
