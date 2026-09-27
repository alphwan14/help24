-- =============================================================================
-- Migration 117: shared alert reviews, and two finance repairs
-- =============================================================================
-- ADDITIVE. Creates two append-only tables and two server-only functions; alters
-- nothing that exists, and writes to money tables ONLY when an admin calls one
-- of the functions below (never at apply time).
--
-- 1. admin_alert_reviews
--    Which admin reviewed which dashboard alert, for exactly which set of
--    records (the alert's fingerprint), and why. The bell reads it, so a
--    reviewed alert is quiet for EVERY admin — and raised again the moment a
--    record joins or leaves it. Replaces a per-browser acknowledgement that
--    nobody else could see and that was lost whenever a check was briefly
--    unavailable.
--
-- 2. admin_finance_actions
--    Append-only audit of the two repairs below: who, in what role, why, the
--    payment reference, and the state before and after.
--
-- 3. admin_record_manual_settlement(...)
--    FULL_REFUND and PARTIAL_SPLIT rulings are "recorded; cash settled manually
--    by finance" (DecisionsService.applyFinancial) — and nothing recorded that
--    finance ever paid. This records it, in the settlements ledger the rulings
--    already reference: the amount comes from the RULING, never from the
--    caller; an `owed` leg is voided and a `completed` manual leg written in
--    its place (the ledger's own retry pattern, migration 058); a leg already
--    paid, or an automated payment still in flight, is refused.
--
-- 4. admin_apply_recorded_ruling(...)
--    A dispute closed by the retired legacy resolve path could leave its money
--    frozen in 'disputed' with a ruling on record that never moved it (the
--    Disputes centre refuses decisions on closed cases). This applies the
--    ruling ON RECORD, exactly as the decision engine would have:
--      FULL_REFUND / PARTIAL_SPLIT → transaction + escrow 'refunded' (in SQL);
--      FULL_RELEASE → the money is unfrozen ('paid' / 'locked') in one locked
--        step — which a second caller cannot repeat — and the backend then
--        dispatches the M-Pesa payout through the normal release path. If that
--        dispatch fails, calling again retries it.
--
-- Depends on 115 (moderation_assert_trusted, moderation_require_admin).
--
-- Rollback (nothing depends on these objects except the backend's
-- /admin/alerts reviews and /admin/finance routes, which fail closed without them):
--   DROP FUNCTION IF EXISTS public.admin_apply_recorded_ruling(uuid, uuid, text, text),
--     public.admin_record_manual_settlement(uuid, uuid, text, text, text, text, text),
--     public.fn_admin_append_only();
--   DROP TABLE IF EXISTS public.admin_finance_actions, public.admin_alert_reviews;
--   (Settlement legs and payment states written by the functions remain — they
--    are the record of what finance did, and must not be rolled back blindly.)
-- =============================================================================

BEGIN;

-- ── 1. Alert reviews ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.admin_alert_reviews (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_id     text        NOT NULL CHECK (alert_id ~ '^[a-z][a-z_]{2,39}$'),
  fingerprint  text        NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{16}$'),
  action       text        NOT NULL CHECK (action IN ('reviewed', 'reopened')),
  note         text,
  admin_id     uuid        NOT NULL REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  admin_email  text        NOT NULL,
  admin_role   text        NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT admin_alert_reviews_note CHECK (
    (action = 'reviewed' AND char_length(btrim(coalesce(note, ''))) BETWEEN 5 AND 500)
    OR (action = 'reopened' AND (note IS NULL OR char_length(note) <= 500))
  )
);

CREATE INDEX IF NOT EXISTS idx_admin_alert_reviews_alert
  ON public.admin_alert_reviews (alert_id, created_at DESC);

-- ── 2. Finance action audit ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.admin_finance_actions (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  action_type     text        NOT NULL CHECK (action_type IN ('manual_settlement_recorded', 'ruling_applied')),
  transaction_id  uuid        NOT NULL REFERENCES public.transactions(id) ON DELETE RESTRICT,
  dispute_id      uuid        REFERENCES public.disputes(id) ON DELETE RESTRICT,
  decision_id     uuid        REFERENCES public.dispute_decisions(id) ON DELETE RESTRICT,
  settlement_id   uuid        REFERENCES public.settlements(id) ON DELETE RESTRICT,
  admin_id        uuid        NOT NULL REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  admin_email     text        NOT NULL,
  admin_role      text        NOT NULL,
  reason          text        NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 5 AND 1000),
  reference       text        CHECK (reference IS NULL OR char_length(reference) BETWEEN 3 AND 64),
  previous_state  jsonb       NOT NULL DEFAULT '{}'::jsonb,
  new_state       jsonb       NOT NULL DEFAULT '{}'::jsonb,
  request_id      text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_finance_actions_tx
  ON public.admin_finance_actions (transaction_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_finance_actions_dispute
  ON public.admin_finance_actions (dispute_id, created_at DESC);

-- ── Both are append-only, for everyone ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_admin_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'HELP24_APPEND_ONLY: rows in % cannot be changed or removed', TG_TABLE_NAME
    USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS trg_admin_alert_reviews_append_only ON public.admin_alert_reviews;
CREATE TRIGGER trg_admin_alert_reviews_append_only
  BEFORE UPDATE OR DELETE ON public.admin_alert_reviews
  FOR EACH ROW EXECUTE FUNCTION public.fn_admin_append_only();
DROP TRIGGER IF EXISTS trg_admin_alert_reviews_no_truncate ON public.admin_alert_reviews;
CREATE TRIGGER trg_admin_alert_reviews_no_truncate
  BEFORE TRUNCATE ON public.admin_alert_reviews
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_admin_append_only();

DROP TRIGGER IF EXISTS trg_admin_finance_actions_append_only ON public.admin_finance_actions;
CREATE TRIGGER trg_admin_finance_actions_append_only
  BEFORE UPDATE OR DELETE ON public.admin_finance_actions
  FOR EACH ROW EXECUTE FUNCTION public.fn_admin_append_only();
DROP TRIGGER IF EXISTS trg_admin_finance_actions_no_truncate ON public.admin_finance_actions;
CREATE TRIGGER trg_admin_finance_actions_no_truncate
  BEFORE TRUNCATE ON public.admin_finance_actions
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_admin_append_only();

-- =============================================================================
-- 3. admin_record_manual_settlement
-- =============================================================================
CREATE OR REPLACE FUNCTION public.admin_record_manual_settlement(
  p_admin_id       uuid,
  p_transaction_id uuid,
  p_direction      text,
  p_reference      text,
  p_reason         text,
  p_environment    text,
  p_request_id     text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin   public.admin_users%ROWTYPE;
  v_tx      public.transactions%ROWTYPE;
  v_escrow  public.escrow%ROWTYPE;
  v_dispute public.disputes%ROWTYPE;
  v_dec     public.dispute_decisions%ROWTYPE;
  v_open    public.settlements%ROWTYPE;
  v_amount  integer;
  v_benef   text;
  v_new     uuid;
  v_action  uuid;
  v_reason  text := btrim(coalesce(p_reason, ''));
  v_ref     text := btrim(coalesce(p_reference, ''));
BEGIN
  PERFORM public.moderation_assert_trusted();
  v_admin := public.moderation_require_admin(p_admin_id);
  IF v_admin.role NOT IN ('senior_admin', 'super_admin') THEN
    RAISE EXCEPTION 'HELP24_FINANCE_FORBIDDEN: recording a settlement needs a senior admin' USING ERRCODE = '42501';
  END IF;
  IF p_direction IS NULL OR p_direction NOT IN ('provider_payout', 'client_refund') THEN
    RAISE EXCEPTION 'HELP24_FINANCE_INVALID: direction must be provider_payout or client_refund' USING ERRCODE = '22023';
  END IF;
  IF p_environment IS NULL OR p_environment NOT IN ('sandbox', 'production') THEN
    RAISE EXCEPTION 'HELP24_FINANCE_INVALID: environment must be sandbox or production' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_reason) < 5 OR char_length(v_reason) > 1000 THEN
    RAISE EXCEPTION 'HELP24_FINANCE_INVALID: say how it was paid, in 5 to 1000 characters' USING ERRCODE = '22023';
  END IF;
  IF v_ref !~ '^[A-Za-z0-9][A-Za-z0-9 ._/#-]{2,63}$' THEN
    RAISE EXCEPTION 'HELP24_FINANCE_INVALID: give the payment reference (the M-Pesa code or bank reference), 3 to 64 characters'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_FINANCE_NOT_FOUND: payment not found' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_escrow FROM public.escrow WHERE transaction_id = v_tx.id;
  IF v_tx.status IS DISTINCT FROM 'refunded' OR v_escrow.status IS DISTINCT FROM 'refunded' THEN
    RAISE EXCEPTION 'HELP24_FINANCE_CONFLICT: only money a ruling handed to finance can be recorded as paid by hand — this payment is % with escrow %',
      v_tx.status, coalesce(v_escrow.status, 'missing') USING ERRCODE = '23505';
  END IF;

  -- The ruling that told finance to pay by hand.
  SELECT * INTO v_dispute FROM public.disputes
   WHERE transaction_id = v_tx.id ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_FINANCE_CONFLICT: there is no dispute ruling for this payment' USING ERRCODE = '23505';
  END IF;
  SELECT * INTO v_dec FROM public.dispute_decisions
   WHERE dispute_id = v_dispute.id AND decision_type <> 'ESCALATE'
   ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_FINANCE_CONFLICT: there is no ruling on record for this dispute' USING ERRCODE = '23505';
  END IF;

  IF p_direction = 'provider_payout' THEN
    IF v_dec.decision_type <> 'PARTIAL_SPLIT' OR coalesce(v_dec.provider_amount, 0) <= 0 THEN
      RAISE EXCEPTION 'HELP24_FINANCE_CONFLICT: this ruling owes the provider nothing to pay by hand (%)', v_dec.decision_type
        USING ERRCODE = '23505';
    END IF;
    v_amount := v_dec.provider_amount;
    SELECT p.selected_provider_id INTO v_benef FROM public.posts p WHERE p.id = v_tx.post_id;
  ELSE
    IF v_dec.decision_type NOT IN ('FULL_REFUND', 'PARTIAL_SPLIT') OR coalesce(v_dec.client_refund_amount, 0) <= 0 THEN
      RAISE EXCEPTION 'HELP24_FINANCE_CONFLICT: this ruling refunds the client nothing (%)', v_dec.decision_type
        USING ERRCODE = '23505';
    END IF;
    v_amount := v_dec.client_refund_amount;
    v_benef := v_tx.buyer_user_id;
  END IF;

  -- One live leg per (payment, direction) — the ledger's own unique index.
  SELECT * INTO v_open FROM public.settlements
   WHERE transaction_id = v_tx.id AND direction = p_direction
     AND status IN ('initiated', 'pending', 'owed', 'succeeded', 'recorded', 'completed', 'retained', 'refunded')
   FOR UPDATE;
  IF FOUND THEN
    IF v_open.status IN ('succeeded', 'completed') THEN
      RAISE EXCEPTION 'HELP24_FINANCE_CONFLICT: this is already recorded as paid (%)', v_open.status USING ERRCODE = '23505';
    ELSIF v_open.status IN ('initiated', 'pending') THEN
      RAISE EXCEPTION 'HELP24_FINANCE_CONFLICT: an automated payment for this is still in flight — reconcile it instead'
        USING ERRCODE = '23505';
    END IF;
    UPDATE public.settlements
       SET status = 'voided',
           failure_reason = left('Superseded: paid by hand, reference ' || v_ref, 500)
     WHERE id = v_open.id;
  END IF;

  INSERT INTO public.settlements
    (transaction_id, escrow_id, post_id, direction, rail, amount, beneficiary_user_id, status,
     mpesa_receipt, attempts, last_attempt_at, environment, reason_ref_type, reason_ref_id,
     created_by, settled_at)
  VALUES
    (v_tx.id, v_escrow.id, v_tx.post_id::text, p_direction, 'manual', v_amount, v_benef, 'completed',
     v_ref, 1, now(), p_environment, 'dispute_decision', v_dec.id::text,
     v_admin.email, now())
  RETURNING id INTO v_new;

  INSERT INTO public.admin_finance_actions
    (action_type, transaction_id, dispute_id, decision_id, settlement_id, admin_id, admin_email,
     admin_role, reason, reference, previous_state, new_state, request_id)
  VALUES
    ('manual_settlement_recorded', v_tx.id, v_dispute.id, v_dec.id, v_new, v_admin.id, v_admin.email,
     v_admin.role, v_reason, v_ref,
     jsonb_build_object('leg', CASE WHEN v_open.id IS NULL THEN NULL
       ELSE jsonb_build_object('id', v_open.id, 'status', v_open.status, 'rail', v_open.rail, 'amount', v_open.amount) END),
     jsonb_build_object('leg', jsonb_build_object('id', v_new, 'status', 'completed', 'rail', 'manual',
       'direction', p_direction, 'amount', v_amount)),
     p_request_id)
  RETURNING id INTO v_action;

  RETURN jsonb_build_object(
    'settlement_id', v_new, 'voided_leg_id', v_open.id, 'direction', p_direction,
    'amount', v_amount, 'beneficiary_user_id', v_benef, 'decision_id', v_dec.id, 'action_id', v_action);
END;
$$;

-- =============================================================================
-- 4. admin_apply_recorded_ruling
-- =============================================================================
CREATE OR REPLACE FUNCTION public.admin_apply_recorded_ruling(
  p_admin_id   uuid,
  p_dispute_id uuid,
  p_reason     text,
  p_request_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_closed  CONSTANT text[] := ARRAY['resolved', 'resolved_release', 'resolved_refund', 'resolved_partial'];
  c_active  CONSTANT text[] := ARRAY['open', 'reviewing', 'under_review', 'escalated', 'awaiting_client_evidence',
                                     'awaiting_provider_evidence', 'awaiting_admin_review'];
  v_admin   public.admin_users%ROWTYPE;
  v_dispute public.disputes%ROWTYPE;
  v_tx      public.transactions%ROWTYPE;
  v_escrow  public.escrow%ROWTYPE;
  v_dec     public.dispute_decisions%ROWTYPE;
  v_action  uuid;
  v_phase   text;
  v_reason  text := btrim(coalesce(p_reason, ''));
BEGIN
  PERFORM public.moderation_assert_trusted();
  v_admin := public.moderation_require_admin(p_admin_id);
  IF v_admin.role NOT IN ('senior_admin', 'super_admin') THEN
    RAISE EXCEPTION 'HELP24_FINANCE_FORBIDDEN: applying a ruling needs a senior admin' USING ERRCODE = '42501';
  END IF;
  IF char_length(v_reason) < 5 OR char_length(v_reason) > 1000 THEN
    RAISE EXCEPTION 'HELP24_FINANCE_INVALID: give a reason of 5 to 1000 characters' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_dispute FROM public.disputes WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_FINANCE_NOT_FOUND: dispute not found' USING ERRCODE = '22023';
  END IF;
  IF NOT (v_dispute.status = ANY (c_closed)) THEN
    RAISE EXCEPTION 'HELP24_FINANCE_CONFLICT: this dispute is not closed (%) — decide it in the Disputes centre', v_dispute.status
      USING ERRCODE = '23505';
  END IF;
  IF v_dispute.transaction_id IS NULL THEN
    RAISE EXCEPTION 'HELP24_FINANCE_CONFLICT: this dispute has no payment attached' USING ERRCODE = '23505';
  END IF;
  IF EXISTS (SELECT 1 FROM public.disputes d
              WHERE d.id <> v_dispute.id
                AND (d.transaction_id = v_dispute.transaction_id OR d.post_id = v_dispute.post_id)
                AND d.status = ANY (c_active)) THEN
    RAISE EXCEPTION 'HELP24_FINANCE_CONFLICT: another dispute on this job is still open — it decides the money'
      USING ERRCODE = '23505';
  END IF;

  SELECT * INTO v_dec FROM public.dispute_decisions
   WHERE dispute_id = v_dispute.id AND decision_type <> 'ESCALATE'
   ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_FINANCE_CONFLICT: there is no ruling on record to apply — this needs manual investigation'
      USING ERRCODE = '23505';
  END IF;

  SELECT * INTO v_tx FROM public.transactions WHERE id = v_dispute.transaction_id FOR UPDATE;
  SELECT * INTO v_escrow FROM public.escrow WHERE transaction_id = v_tx.id;

  IF v_tx.status = 'disputed' THEN
    IF v_dec.decision_type = 'FULL_RELEASE' THEN
      -- Unfreeze in this locked step; the backend then releases through the
      -- normal payout path. A second caller finds the money no longer frozen.
      UPDATE public.transactions SET status = 'paid' WHERE id = v_tx.id;
      UPDATE public.escrow SET status = 'locked' WHERE transaction_id = v_tx.id;
      v_phase := 'unfrozen_for_release';
    ELSE
      -- FULL_REFUND / PARTIAL_SPLIT: exactly what the decision engine records;
      -- the cash is then settled by finance (see admin_record_manual_settlement).
      UPDATE public.transactions SET status = 'refunded' WHERE id = v_tx.id;
      UPDATE public.escrow SET status = 'refunded', released_at = now() WHERE transaction_id = v_tx.id;
      v_phase := 'applied';
    END IF;
  ELSIF v_tx.status = 'paid' AND v_dec.decision_type = 'FULL_RELEASE'
        AND EXISTS (SELECT 1 FROM public.admin_finance_actions a
                     WHERE a.dispute_id = v_dispute.id AND a.action_type = 'ruling_applied') THEN
    -- Unfrozen earlier by this function, but the payout never went out: retry it.
    v_phase := 'retry_release';
  ELSE
    RAISE EXCEPTION 'HELP24_FINANCE_CONFLICT: nothing to apply — the payment is % and the ruling is %',
      v_tx.status, v_dec.decision_type USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.admin_finance_actions
    (action_type, transaction_id, dispute_id, decision_id, admin_id, admin_email, admin_role,
     reason, previous_state, new_state, request_id)
  VALUES
    ('ruling_applied', v_tx.id, v_dispute.id, v_dec.id, v_admin.id, v_admin.email, v_admin.role,
     v_reason,
     jsonb_build_object('transaction', v_tx.status, 'escrow', v_escrow.status),
     jsonb_build_object('phase', v_phase, 'ruling', v_dec.decision_type,
       'transaction', CASE v_phase WHEN 'applied' THEN 'refunded' WHEN 'unfrozen_for_release' THEN 'paid' ELSE v_tx.status END,
       'escrow', CASE v_phase WHEN 'applied' THEN 'refunded' WHEN 'unfrozen_for_release' THEN 'locked' ELSE v_escrow.status END),
     p_request_id)
  RETURNING id INTO v_action;

  RETURN jsonb_build_object(
    'phase', v_phase,
    'decision_type', v_dec.decision_type,
    'decision_id', v_dec.id,
    'post_id', v_dispute.post_id,
    'transaction_id', v_tx.id,
    'needs_payout', v_phase IN ('unfrozen_for_release', 'retry_release'),
    'action_id', v_action);
END;
$$;

-- ── Access: the backend only ─────────────────────────────────────────────────
ALTER TABLE public.admin_alert_reviews   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_finance_actions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.admin_alert_reviews   FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON public.admin_finance_actions FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT ON public.admin_alert_reviews   TO service_role;
GRANT SELECT         ON public.admin_finance_actions TO service_role;

REVOKE ALL ON FUNCTION public.fn_admin_append_only() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_record_manual_settlement(uuid, uuid, text, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_apply_recorded_ruling(uuid, uuid, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_record_manual_settlement(uuid, uuid, text, text, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_apply_recorded_ruling(uuid, uuid, text, text) TO service_role;

COMMIT;
