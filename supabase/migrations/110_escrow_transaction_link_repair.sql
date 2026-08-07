-- =============================================================================
-- Migration 110 — repair six escrow rows bound to a failed transaction
-- =============================================================================
-- ⚠️ NOT YET APPLIED. Requires explicit approval before it is run anywhere.
--    Design, evidence and rollback: docs/escrow-repair-deployment-report.md
--
-- WHAT WENT WRONG
-- ---------------
-- Escrow is inserted optimistically when a payment is INITIATED, before the
-- payment is known to succeed (backend/src/mpesa/mpesa.service.ts:297-310).
-- When that payment then fails, the escrow row is never removed: the post keeps
-- a `locked` escrow row bound to a transaction that failed.
--
-- A retry is allowed (initiate only blocks on `pending`/`paid` transactions), so
-- a second transaction is created — and ITS optimistic insert dies on
-- `escrow_job_id_key UNIQUE (post_id)`, because the post already has a row.
--
-- The `payment.success` handler exists to repair exactly that. It never could:
-- it upserted with `onConflict: 'transaction_id'` against a table with no unique
-- constraint on that column, so Postgres rejected every call with
--   "there is no unique or exclusion constraint matching the ON CONFLICT specification"
-- All eleven such events are in dead-letter with that identical error.
--
-- Net result on six posts: the escrow row points at the FAILED attempt, and the
-- SUCCESSFUL transaction has no escrow row of its own.
--
-- NOTE FOR ANYONE REACHING FOR THE OBVIOUS FIX
-- --------------------------------------------
-- Adding `UNIQUE (escrow.transaction_id)` does NOT fix the handler, and this was
-- verified against production inside a rolled-back transaction: the INSERT then
-- becomes valid SQL but still violates `escrow_job_id_key`, because a row for
-- that post already exists under a different transaction. The correct conflict
-- key is `post_id`, which is ALREADY unique — so the code fix
-- (commit accompanying this migration) needs no schema change, and neither does
-- this repair.
--
-- WHAT THIS MIGRATION DOES
-- ------------------------
-- Re-points six existing escrow rows at the transaction that actually funded
-- them, and corrects the two whose status never caught up.
--
--   • NO rows are inserted. NO rows are deleted. NO amount is altered.
--   • Row count before and after: 17. Amount sum before and after: 73,250.
--   • Every other escrow row is byte-identical afterwards (verified by
--     fingerprint in the dry run).
--   • Written as explicit literals rather than a derived query ON PURPOSE: a
--     one-time repair should touch exactly the rows that were reviewed, and
--     nothing a later payment might have added.
--
-- IDEMPOTENT
-- ----------
-- Each statement is guarded on the stale `transaction_id`. Re-running matches
-- zero rows. Proven in the dry run: pass 1 updated 6, passes 2 and 3 updated 0.
--
-- ROLLBACK
-- --------
-- See the block at the foot of this file. It restores each row's previous
-- transaction_id and status, and is likewise guarded and idempotent.
-- =============================================================================

BEGIN;

-- ── Pre-flight: refuse to run against a state we did not review ──────────────
-- If any of the six rows has moved since the dry run, abort rather than repair
-- a situation nobody looked at.
DO $$
DECLARE v_expected int;
BEGIN
  SELECT count(*) INTO v_expected
  FROM public.escrow
  WHERE (id, transaction_id) IN (
    ('eb4d5953-4abc-4cdb-be4a-e51461cddf39'::uuid, '982d2615-5bde-4e86-9b2d-c44627e310ea'::uuid),
    ('c1dba5b1-570a-4f7a-904e-5d5217b6dfda'::uuid, '5fc88353-1f9b-410b-b10a-2f8bf1a32870'::uuid),
    ('c14bff3a-d045-45fa-98c1-c20e8d973a92'::uuid, '94278d0f-7948-4823-9cbe-0c00687e133f'::uuid),
    ('fc257cca-2358-4957-bd9d-6b26a3fc145e'::uuid, 'f24e8e73-3493-4978-9b17-d49dfcdc5988'::uuid),
    ('b9885bd0-60d8-42c1-98fc-c76e6bc015ab'::uuid, '1b0e6d40-81f3-476e-91fe-d57e8536bad9'::uuid),
    ('0122736e-50db-4a13-abf4-03947fe3027b'::uuid, '6db9acaf-5552-4221-8880-228818810bd3'::uuid)
  );

  IF v_expected = 0 THEN
    RAISE NOTICE '[110] Already applied (0 of 6 rows in the pre-repair state). Nothing to do.';
  ELSIF v_expected <> 6 THEN
    RAISE EXCEPTION
      '[110] ABORT: expected 6 rows in the pre-repair state, found %. The data '
      'moved since this migration was reviewed. Re-run the dry run in '
      'docs/escrow-repair-deployment-report.md before proceeding.', v_expected;
  END IF;
END $$;

-- ── The repair ───────────────────────────────────────────────────────────────
-- Each UPDATE names the row, asserts the stale transaction it must currently
-- hold, and sets the funding transaction plus the status that transaction implies.
-- Status mapping is taken from the rows that ARE correctly linked in production:
--   tx paid → locked · payout_pending → payout_pending · refunded → refunded
--   disputed → disputed · released → released

-- post 6b8e311f… — KES 500, funding tx is `paid`
UPDATE public.escrow SET transaction_id = '20bc6501-67ff-4717-9671-3847366690ff', status = 'locked'
 WHERE id = 'eb4d5953-4abc-4cdb-be4a-e51461cddf39' AND transaction_id = '982d2615-5bde-4e86-9b2d-c44627e310ea';

-- post 3a405e92… — KES 20,000, funding tx is `paid`
UPDATE public.escrow SET transaction_id = '8f40ceee-1abd-43f2-9a72-4a62427160ee', status = 'locked'
 WHERE id = 'c1dba5b1-570a-4f7a-904e-5d5217b6dfda' AND transaction_id = '5fc88353-1f9b-410b-b10a-2f8bf1a32870';

-- post 7f08b6a6… — KES 1,200, funding tx is `paid`
UPDATE public.escrow SET transaction_id = '827c4c9a-7453-4b0f-809b-9bbd3642a9f8', status = 'locked'
 WHERE id = 'c14bff3a-d045-45fa-98c1-c20e8d973a92' AND transaction_id = '94278d0f-7948-4823-9cbe-0c00687e133f';

-- post 8b4a656b… — KES 250, funding tx is `disputed`; escrow must be frozen to match
UPDATE public.escrow SET transaction_id = '93962229-f24d-45d0-bb03-20144a1deca4', status = 'disputed'
 WHERE id = 'fc257cca-2358-4957-bd9d-6b26a3fc145e' AND transaction_id = 'f24e8e73-3493-4978-9b17-d49dfcdc5988';

-- post e8625809… — KES 1,800, funding tx is `paid`
UPDATE public.escrow SET transaction_id = 'f5ede71f-9942-49b6-8829-da1ec2208f40', status = 'locked'
 WHERE id = 'b9885bd0-60d8-42c1-98fc-c76e6bc015ab' AND transaction_id = '1b0e6d40-81f3-476e-91fe-d57e8536bad9';

-- post c5acf72a… — KES 800, funding tx is `payout_pending`; escrow must match
UPDATE public.escrow SET transaction_id = 'e1bbfde8-d7e6-43cb-92cd-23b00c9d213d', status = 'payout_pending'
 WHERE id = '0122736e-50db-4a13-abf4-03947fe3027b' AND transaction_id = '6db9acaf-5552-4221-8880-228818810bd3';

-- ── Post-flight: refuse to commit a partial or over-broad repair ─────────────
DO $$
DECLARE v_orphans int; v_rows int; v_sum bigint; v_dup int;
BEGIN
  SELECT count(*) INTO v_orphans
  FROM public.transactions t
  LEFT JOIN public.escrow e ON e.transaction_id = t.id
  WHERE e.id IS NULL AND t.status IN ('paid','payout_pending','released','disputed','refunded');

  SELECT count(*), sum(amount) INTO v_rows, v_sum FROM public.escrow;
  SELECT count(*) INTO v_dup FROM (
    SELECT transaction_id FROM public.escrow WHERE transaction_id IS NOT NULL
    GROUP BY transaction_id HAVING count(*) > 1) d;

  IF v_orphans <> 0 THEN
    RAISE EXCEPTION '[110] ABORT: % funded transaction(s) still have no escrow row.', v_orphans;
  END IF;
  IF v_rows <> 17 THEN
    RAISE EXCEPTION '[110] ABORT: escrow row count is % (expected 17 — this migration inserts and deletes nothing).', v_rows;
  END IF;
  IF v_sum <> 73250 THEN
    RAISE EXCEPTION '[110] ABORT: escrow amount sum is % (expected 73250 — this migration alters no amount).', v_sum;
  END IF;
  IF v_dup <> 0 THEN
    RAISE EXCEPTION '[110] ABORT: % duplicate transaction_id(s) in escrow.', v_dup;
  END IF;

  RAISE NOTICE '[110] OK — 6 rows re-pointed, 17 rows total, sum 73250, no orphans, no duplicates.';
END $$;

COMMIT;

-- =============================================================================
-- ROLLBACK — restores the exact pre-repair state. Guarded and idempotent.
-- =============================================================================
-- BEGIN;
--
-- UPDATE public.escrow SET transaction_id = '982d2615-5bde-4e86-9b2d-c44627e310ea', status = 'locked'
--  WHERE id = 'eb4d5953-4abc-4cdb-be4a-e51461cddf39' AND transaction_id = '20bc6501-67ff-4717-9671-3847366690ff';
--
-- UPDATE public.escrow SET transaction_id = '5fc88353-1f9b-410b-b10a-2f8bf1a32870', status = 'locked'
--  WHERE id = 'c1dba5b1-570a-4f7a-904e-5d5217b6dfda' AND transaction_id = '8f40ceee-1abd-43f2-9a72-4a62427160ee';
--
-- UPDATE public.escrow SET transaction_id = '94278d0f-7948-4823-9cbe-0c00687e133f', status = 'locked'
--  WHERE id = 'c14bff3a-d045-45fa-98c1-c20e8d973a92' AND transaction_id = '827c4c9a-7453-4b0f-809b-9bbd3642a9f8';
--
-- UPDATE public.escrow SET transaction_id = 'f24e8e73-3493-4978-9b17-d49dfcdc5988', status = 'locked'
--  WHERE id = 'fc257cca-2358-4957-bd9d-6b26a3fc145e' AND transaction_id = '93962229-f24d-45d0-bb03-20144a1deca4';
--
-- UPDATE public.escrow SET transaction_id = '1b0e6d40-81f3-476e-91fe-d57e8536bad9', status = 'locked'
--  WHERE id = 'b9885bd0-60d8-42c1-98fc-c76e6bc015ab' AND transaction_id = 'f5ede71f-9942-49b6-8829-da1ec2208f40';
--
-- UPDATE public.escrow SET transaction_id = '6db9acaf-5552-4221-8880-228818810bd3', status = 'locked'
--  WHERE id = '0122736e-50db-4a13-abf4-03947fe3027b' AND transaction_id = 'e1bbfde8-d7e6-43cb-92cd-23b00c9d213d';
--
-- COMMIT;
-- =============================================================================
