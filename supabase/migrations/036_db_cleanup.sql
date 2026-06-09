-- =============================================================================
-- Migration 036: Database cleanup
-- =============================================================================
-- Run AFTER 035. All statements are idempotent (safe to re-run).
--
-- Cleans:
--   1. Orphan chats (no messages) — belt-and-suspenders after 028
--   2. Duplicate chats for the same post + user pair (keeps the oldest)
--   3. Posts with inconsistent status vs. transaction state
--   4. system_events: no cleanup needed (new table)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Delete orphan chats (belt-and-suspenders; 028 already ran this once)
-- ---------------------------------------------------------------------------
DELETE FROM public.chats
WHERE NOT EXISTS (
  SELECT 1 FROM public.chat_messages cm WHERE cm.chat_id = chats.id
);

-- ---------------------------------------------------------------------------
-- 2. Remove duplicate chats for the same (post_id, user1, user2) triplet.
--    Keeps the oldest chat row; deletes the newer duplicates.
--    chat_messages FK is ON DELETE CASCADE so messages are removed too.
-- ---------------------------------------------------------------------------
DELETE FROM public.chats
WHERE id IN (
  SELECT id
  FROM (
    SELECT
      id,
      ROW_NUMBER() OVER (
        PARTITION BY post_id, user1, user2
        ORDER BY created_at ASC          -- keep the oldest
      ) AS rn
    FROM public.chats
    WHERE post_id IS NOT NULL
  ) ranked
  WHERE rn > 1
);

-- ---------------------------------------------------------------------------
-- 3. Fix posts whose status doesn't match the underlying transaction state.
--
--    Rule: if a post has status='open' or 'assigned' but its latest
--    transaction has status='released', the post should be 'completed'.
-- ---------------------------------------------------------------------------
UPDATE public.posts p
   SET status = 'completed'
 WHERE p.status IN ('open', 'assigned')
   AND EXISTS (
     SELECT 1
     FROM public.transactions t
     WHERE t.post_id = p.id
       AND t.status  = 'released'
   );

-- Rule: if a post has status='open' or 'assigned' but its latest
-- transaction has status='disputed', the post should be 'disputed'.
UPDATE public.posts p
   SET status = 'disputed'
 WHERE p.status IN ('open', 'assigned')
   AND EXISTS (
     SELECT 1
     FROM public.transactions t
     WHERE t.post_id = p.id
       AND t.status  = 'disputed'
   );

-- ---------------------------------------------------------------------------
-- 4. Ensure escrow rows exist for every 'paid' or beyond transaction.
--    If the escrow row was orphaned (initiatePayment() failed the insert),
--    create it now. Amount comes from transactions.amount.
-- ---------------------------------------------------------------------------
INSERT INTO public.escrow (post_id, transaction_id, amount, status)
SELECT
  t.post_id::text,
  t.id,
  t.amount,
  CASE
    WHEN t.status = 'released'       THEN 'released'
    WHEN t.status = 'refunded'       THEN 'refunded'
    WHEN t.status = 'disputed'       THEN 'disputed'
    WHEN t.status = 'payout_pending' THEN 'payout_pending'
    ELSE 'locked'
  END
FROM public.transactions t
WHERE t.status IN ('paid','payout_pending','released','disputed','refunded')
  AND NOT EXISTS (
    SELECT 1 FROM public.escrow e WHERE e.transaction_id = t.id
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.escrow e WHERE e.post_id = t.post_id::text
  );

-- ---------------------------------------------------------------------------
-- 5. Verify counts (comment out for production; useful during dev rollout)
-- ---------------------------------------------------------------------------
-- SELECT 'orphan chats remaining' AS check, COUNT(*) FROM public.chats
--   WHERE NOT EXISTS (SELECT 1 FROM public.chat_messages cm WHERE cm.chat_id = chats.id);
--
-- SELECT 'posts with status/tx mismatch' AS check, COUNT(*) FROM public.posts p
--   WHERE p.status NOT IN ('completed','disputed')
--     AND EXISTS (SELECT 1 FROM public.transactions t WHERE t.post_id=p.id AND t.status='released');
--
-- SELECT 'transactions missing escrow' AS check, COUNT(*) FROM public.transactions t
--   WHERE t.status IN ('paid','payout_pending','released','disputed','refunded')
--     AND NOT EXISTS (SELECT 1 FROM public.escrow e WHERE e.transaction_id = t.id);
