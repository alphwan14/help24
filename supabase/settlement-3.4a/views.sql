-- =============================================================================
-- views.sql  (Phase 3.4A — read-only derived escrow state)
-- =============================================================================
-- v_escrow_settlement_derived computes the settlement truth from the legs and
-- compares it to the live escrow.status. READ ONLY — writes nothing, mutates
-- nothing. Deterministic precedence:
--   disputed → locked → payout_pending → split_settled → released → refunded
--            → settlement_failed → inconsistent
-- =============================================================================

CREATE OR REPLACE VIEW public.v_escrow_settlement_derived AS
WITH legs AS (
  SELECT
    transaction_id,
    bool_or(status IN ('initiated','pending','recorded','owed'))            AS any_inflight,
    bool_or(direction = 'provider_payout' AND status = 'succeeded')         AS provider_succeeded,
    bool_or(direction = 'provider_payout')                                  AS has_provider,
    bool_or(direction = 'client_refund'  AND status = 'completed')          AS refund_completed,
    bool_or(direction = 'client_refund')                                    AS has_refund,
    bool_or(status = 'failed')                                              AS any_failed,
    bool_or(direction = 'provider_payout' AND status = 'succeeded')
      AND bool_or(direction = 'client_refund' AND status IN ('recorded','owed')) AS refund_outstanding
  FROM public.settlements
  WHERE status <> 'voided'
  GROUP BY transaction_id
),
derived AS (
  SELECT
    e.id            AS escrow_id,
    e.transaction_id,
    e.status        AS live_status,
    CASE
      WHEN l.transaction_id IS NULL AND disp.active_dispute THEN 'disputed'
      WHEN l.transaction_id IS NULL                          THEN 'locked'
      WHEN l.any_inflight                                    THEN 'payout_pending'
      WHEN l.provider_succeeded AND l.refund_completed       THEN 'split_settled'
      WHEN l.provider_succeeded AND NOT l.has_refund         THEN 'released'
      WHEN l.refund_completed   AND NOT l.has_provider       THEN 'refunded'
      WHEN l.any_failed                                      THEN 'settlement_failed'
      ELSE 'inconsistent'
    END             AS derived_status,
    COALESCE(l.refund_outstanding, FALSE) AS detail_refund_outstanding
  FROM public.escrow e
  LEFT JOIN legs l ON l.transaction_id = e.transaction_id
  LEFT JOIN LATERAL (
    SELECT EXISTS (
      SELECT 1 FROM public.disputes d
      WHERE d.transaction_id = e.transaction_id
        AND d.status NOT IN ('resolved','resolved_release','resolved_refund',
                             'resolved_partial','merged','escalated')
    ) AS active_dispute
  ) disp ON TRUE
)
SELECT
  escrow_id,
  transaction_id,
  live_status,
  derived_status,
  detail_refund_outstanding,
  (derived_status <> live_status) AS diverges
FROM derived;
