-- =============================================================================
-- backfill_settlements.sql  (Phase 3.4A — run ONCE, after migration 058)
-- =============================================================================
-- Synthesizes settlement legs that represent what ALREADY happened. Idempotent:
-- every block is guarded by WHERE NOT EXISTS (transaction_id, direction), so
-- re-running inserts zero rows. Reads existing tables; writes ONLY settlements.
--
-- NEVER updates transactions / escrow / posts. Moves no money.
--
-- NOTE: escrow.post_id may be TEXT in the live DB (diverged from migration 019's
-- UUID); every reference is cast ::text. posts is joined via transactions.post_id
-- (uuid↔uuid) to sidestep the escrow.post_id type entirely.
-- =============================================================================

-- (A) FULL_RELEASE history → provider leg SUCCEEDED -----------------------------
INSERT INTO public.settlements
  (transaction_id, escrow_id, post_id, direction, rail, amount, beneficiary_user_id,
   status, conversation_id, mpesa_receipt, environment, reason_ref_type, reason_ref_id,
   created_by, settled_at)
SELECT t.id, e.id, e.post_id::text, 'provider_payout', 'mpesa_b2c',
       t.amount, COALESCE(e.provider_id, p.selected_provider_id),
       'succeeded', t.conversation_id, t.mpesa_receipt,
       CASE WHEN t.mpesa_receipt LIKE 'DEV%'
              OR t.conversation_id LIKE 'DEV\_%' ESCAPE '\' THEN 'sandbox'
            ELSE 'sandbox' END,                         -- production payouts not yet live
       'backfill', dec.decision_id, 'backfill', e.released_at
FROM public.escrow e
JOIN public.transactions t ON t.id = e.transaction_id
JOIN public.posts p        ON p.id = t.post_id
LEFT JOIN LATERAL (
   SELECT dd.id::text AS decision_id
   FROM public.disputes d
   LEFT JOIN public.dispute_decisions dd ON dd.dispute_id = d.id
   WHERE d.transaction_id = t.id
   ORDER BY dd.created_at DESC NULLS LAST
   LIMIT 1
) dec ON TRUE
WHERE e.status = 'released'
  AND NOT EXISTS (SELECT 1 FROM public.settlements s
                  WHERE s.transaction_id = t.id AND s.direction = 'provider_payout');

-- (B) Stuck payout_pending → provider leg PENDING ------------------------------
INSERT INTO public.settlements
  (transaction_id, escrow_id, post_id, direction, rail, amount, beneficiary_user_id,
   status, conversation_id, environment, reason_ref_type, created_by)
SELECT t.id, e.id, e.post_id::text, 'provider_payout', 'mpesa_b2c',
       t.amount, COALESCE(e.provider_id, p.selected_provider_id),
       'pending', t.conversation_id, 'sandbox', 'backfill', 'backfill'
FROM public.escrow e
JOIN public.transactions t ON t.id = e.transaction_id
JOIN public.posts p        ON p.id = t.post_id
WHERE e.status = 'payout_pending'
  AND NOT EXISTS (SELECT 1 FROM public.settlements s
                  WHERE s.transaction_id = t.id AND s.direction = 'provider_payout');

-- (C1) refunded → client refund leg COMPLETED (unverified) ---------------------
--      Full refund returns principal (amount); split returns buyer_refund.
INSERT INTO public.settlements
  (transaction_id, escrow_id, post_id, direction, rail, amount, beneficiary_user_id,
   status, environment, reason_ref_type, reason_ref_id, backfill_unverified,
   created_by, settled_at)
SELECT t.id, e.id, e.post_id::text, 'client_refund', 'manual',
       CASE WHEN dec.is_split THEN COALESCE(dec.refund_amount, t.amount) ELSE t.amount END,
       t.buyer_user_id,
       'completed', 'sandbox', 'backfill', dec.decision_id, TRUE,
       'backfill', e.released_at
FROM public.escrow e
JOIN public.transactions t ON t.id = e.transaction_id
LEFT JOIN LATERAL (
   SELECT dd.id::text AS decision_id,
          COALESCE(dd.client_refund_amount, d.buyer_refund)   AS refund_amount,
          ( dd.decision_type = 'PARTIAL_SPLIT'
            OR (COALESCE(d.provider_amount,0) > 0 AND COALESCE(d.buyer_refund,0) > 0) ) AS is_split
   FROM public.disputes d
   LEFT JOIN public.dispute_decisions dd ON dd.dispute_id = d.id
   WHERE d.transaction_id = t.id
   ORDER BY dd.created_at DESC NULLS LAST
   LIMIT 1
) dec ON TRUE
WHERE e.status = 'refunded'
  AND NOT EXISTS (SELECT 1 FROM public.settlements s
                  WHERE s.transaction_id = t.id AND s.direction = 'client_refund');

-- (C2) refunded + PARTIAL_SPLIT → provider leg OWED (the liability) ------------
INSERT INTO public.settlements
  (transaction_id, escrow_id, post_id, direction, rail, amount, beneficiary_user_id,
   status, environment, reason_ref_type, reason_ref_id, created_by)
SELECT t.id, e.id, e.post_id::text, 'provider_payout', 'mpesa_b2c',
       dec.provider_amount, COALESCE(e.provider_id, p.selected_provider_id),
       'owed', 'sandbox', 'backfill', dec.decision_id, 'backfill'
FROM public.escrow e
JOIN public.transactions t ON t.id = e.transaction_id
JOIN public.posts p        ON p.id = t.post_id
JOIN LATERAL (
   SELECT dd.id::text AS decision_id,
          COALESCE(dd.provider_amount, d.provider_amount) AS provider_amount,
          ( dd.decision_type = 'PARTIAL_SPLIT'
            OR (COALESCE(d.provider_amount,0) > 0 AND COALESCE(d.buyer_refund,0) > 0) ) AS is_split
   FROM public.disputes d
   LEFT JOIN public.dispute_decisions dd ON dd.dispute_id = d.id
   WHERE d.transaction_id = t.id
   ORDER BY dd.created_at DESC NULLS LAST
   LIMIT 1
) dec ON TRUE
WHERE e.status = 'refunded'
  AND dec.is_split
  AND COALESCE(dec.provider_amount, 0) > 0
  AND NOT EXISTS (SELECT 1 FROM public.settlements s
                  WHERE s.transaction_id = t.id AND s.direction = 'provider_payout');

-- (D) platform_fee leg for every escrow that received any leg ------------------
--     Fee is refunded to client on a full refund; retained otherwise.
INSERT INTO public.settlements
  (transaction_id, escrow_id, post_id, direction, rail, amount,
   status, environment, reason_ref_type, created_by)
SELECT t.id, e.id, e.post_id::text, 'platform_fee', 'internal', COALESCE(t.fee, 0),
       CASE WHEN e.status = 'refunded' AND NOT COALESCE(dec.is_split, FALSE)
            THEN 'refunded' ELSE 'retained' END,
       'sandbox', 'backfill', 'backfill'
FROM public.escrow e
JOIN public.transactions t ON t.id = e.transaction_id
LEFT JOIN LATERAL (
   SELECT ( dd.decision_type = 'PARTIAL_SPLIT'
            OR (COALESCE(d.provider_amount,0) > 0 AND COALESCE(d.buyer_refund,0) > 0) ) AS is_split
   FROM public.disputes d
   LEFT JOIN public.dispute_decisions dd ON dd.dispute_id = d.id
   WHERE d.transaction_id = t.id
   ORDER BY dd.created_at DESC NULLS LAST
   LIMIT 1
) dec ON TRUE
WHERE e.status IN ('released','payout_pending','refunded')
  AND NOT EXISTS (SELECT 1 FROM public.settlements s
                  WHERE s.transaction_id = t.id AND s.direction = 'platform_fee');
