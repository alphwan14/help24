-- =============================================================================
-- validation_reports.sql  (Phase 3.4A — SELECT only, run after backfill)
-- =============================================================================
-- Four read-only reports that gate the 3.4B truth-flip. None mutate data.
-- Run each block; review the output against the "expected anomalies" notes.
-- =============================================================================

-- ── REPORT 1 — PARITY (live vs derived escrow state) --------------------------
-- Expected divergences ONLY: historical PARTIAL_SPLIT (live=refunded vs
-- derived=payout_pending). Any 'inconsistent' row, or any other mismatch,
-- must be investigated before 3.4B.
SELECT
  derived_status,
  live_status,
  detail_refund_outstanding,
  COUNT(*) AS escrows
FROM public.v_escrow_settlement_derived
WHERE diverges OR derived_status = 'inconsistent'
GROUP BY derived_status, live_status, detail_refund_outstanding
ORDER BY escrows DESC;

-- Row-level drill-down for investigation:
-- SELECT * FROM public.v_escrow_settlement_derived
--  WHERE diverges OR derived_status = 'inconsistent'
--  ORDER BY derived_status;


-- ── REPORT 2 — CONSERVATION (Σ settled-out vs total_paid) ---------------------
-- For each transaction that produced legs, settled money out =
--   provider succeeded + client refund completed + fee (retained|refunded).
-- Healthy FULL_RELEASE / FULL_REFUND balance to total_paid (delta = 0).
-- PARTIAL_SPLIT shows a POSITIVE delta = the unpaid provider liability (owed,
-- not yet 'out') — expected. Investigate any NEGATIVE delta or unexplained gap.
SELECT
  t.id                                                  AS transaction_id,
  t.total_paid,
  COALESCE(SUM(s.amount) FILTER (
    WHERE (s.direction = 'provider_payout' AND s.status = 'succeeded')
       OR (s.direction = 'client_refund'  AND s.status = 'completed')
       OR (s.direction = 'platform_fee')
  ), 0)                                                 AS settled_out,
  t.total_paid - COALESCE(SUM(s.amount) FILTER (
    WHERE (s.direction = 'provider_payout' AND s.status = 'succeeded')
       OR (s.direction = 'client_refund'  AND s.status = 'completed')
       OR (s.direction = 'platform_fee')
  ), 0)                                                 AS delta,
  COALESCE(SUM(s.amount) FILTER (
    WHERE s.direction = 'provider_payout' AND s.status = 'owed'
  ), 0)                                                 AS provider_owed
FROM public.transactions t
JOIN public.settlements s ON s.transaction_id = t.id
GROUP BY t.id, t.total_paid
HAVING t.total_paid - COALESCE(SUM(s.amount) FILTER (
    WHERE (s.direction = 'provider_payout' AND s.status = 'succeeded')
       OR (s.direction = 'client_refund'  AND s.status = 'completed')
       OR (s.direction = 'platform_fee')
  ), 0) <> 0
ORDER BY delta DESC;


-- ── REPORT 3 — LIABILITY (PARTIAL_SPLIT provider amounts owed) ----------------
-- The outstanding-payout ledger. Becomes the 3.4E disbursement worklist.
SELECT
  s.beneficiary_user_id                AS provider_id,
  COUNT(*)                             AS owed_legs,
  SUM(s.amount)                        AS total_owed,
  MIN(s.created_at)                    AS oldest_backfilled
FROM public.settlements s
WHERE s.direction = 'provider_payout'
  AND s.status    = 'owed'
GROUP BY s.beneficiary_user_id
ORDER BY total_owed DESC;


-- ── REPORT 4 — UNVERIFIED REFUND EXPOSURE -------------------------------------
-- Manual client refunds recorded as completed during backfill WITHOUT live
-- disbursement proof. Real-money exposure to confirm out-of-band.
SELECT
  s.beneficiary_user_id                AS client_id,
  COUNT(*)                             AS refund_legs,
  SUM(s.amount)                        AS total_unverified_refund,
  MIN(s.created_at)                    AS oldest_backfilled
FROM public.settlements s
WHERE s.direction          = 'client_refund'
  AND s.status             = 'completed'
  AND s.backfill_unverified = TRUE
GROUP BY s.beneficiary_user_id
ORDER BY total_unverified_refund DESC;
