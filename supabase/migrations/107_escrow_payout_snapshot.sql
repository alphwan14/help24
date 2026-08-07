-- =============================================================================
-- Migration 107 — freeze the payout destination onto the escrow (Phase 3)
-- =============================================================================
-- NOT APPLIED. Adds nullable columns only. No existing row is read or written,
-- and every column is NULL for historical escrows — which is exactly what the
-- transitional resolution keys off.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHEN THE DESTINATION BECOMES IMMUTABLE, AND WHY IT IS *ESCROW FUNDING*
-- ─────────────────────────────────────────────────────────────────────────────
-- Four candidate moments, judged on one question: at each, what can an attacker
-- who has taken over the provider's account still steal?
--
--   1. PROVIDER SELECTION — earliest. Nothing is at stake yet: no money exists,
--      selections are casual and frequently abandoned. Freezing here buys no
--      security (there is nothing to redirect) and creates real friction — a
--      provider who legitimately changes their number between being chosen and
--      being paid would be paid to the old one for no reason. It also snapshots
--      a great deal of noise that never becomes a payment.
--
--   2. ESCROW FUNDING — ★ CHOSEN. The first moment money exists and the client
--      has irreversibly committed it. Before this instant there is nothing to
--      steal; after it, both the amount and the recipient are determined.
--
--      The decisive property is WHO CONTROLS THE TIMING. Funding is triggered
--      by the CLIENT. A compromised provider account therefore cannot choose
--      when the freeze happens, so it cannot arrange to change the destination
--      "just before" it. Compare stages 3 and 4, where the trigger is an action
--      the provider (or their attacker) performs at a moment of their choosing.
--
--   3. PROVIDER COMPLETION — the provider marks the work done. Strictly worse
--      than 2 for exactly that reason: an attacker who takes over the account
--      changes the destination and THEN marks complete. The window is
--      attacker-controlled, which makes the control theatre.
--
--   4. CUSTOMER APPROVAL — latest, and effectively today's behaviour. Any
--      takeover at any point in the whole job lifecycle captures the payout.
--      Every hour of a multi-week job is an exposure window.
--
-- Chosen: FUNDING. In code this is the `escrow` INSERT inside
-- `MpesaService.initiatePayment` — a hair EARLIER than payment confirmation,
-- since the row is written when the STK push is issued. Earlier is strictly
-- safer here: a destination change during the seconds between initiation and
-- the Daraja callback cannot affect a snapshot already taken.
--
-- What this does NOT protect against, stated plainly: a takeover that happens
-- BEFORE funding. Nothing at the escrow layer can, because at that point the
-- attacker's destination is simply the provider's destination. That threat is
-- answered by the OTP on the destination itself and by change notifications —
-- not by the snapshot.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHICH FIELDS ARE FROZEN, AND WHY EACH ONE
-- ─────────────────────────────────────────────────────────────────────────────
-- The test for inclusion: can a reader in 2030, holding ONLY this JSON, answer
-- the question without joining anything that might have changed or been
-- archived? A foreign key alone fails that test — it answers "which row",
-- not "what did that row say at the time".
--
--   destination_id       FREEZE. The link into the full history: every prior
--                        value, the retirement, the challenge. Without it the
--                        snapshot is an orphan fact.
--
--   normalized_destination
--                        FREEZE — the single most important field. It is what
--                        the money actually went to. Everything else is
--                        context; this is the answer.
--
--   channel              FREEZE. Determines what the value MEANS. `254…` under
--                        `mpesa` is a wallet; the same digits under a future
--                        `bank` channel could be an account number. It also
--                        determines which rail's reversal and dispute rules
--                        applied. Without it the destination is ambiguous the
--                        moment a second channel exists.
--
--   verified_at          FREEZE. Lets an auditor ask the sharpest available
--                        question: was trust established BEFORE the money was
--                        committed? A verification dated after `captured_at` is
--                        a red flag that no other field exposes.
--
--   verification_method  FREEZE. `otp` and `migration` are not the same claim.
--                        A dispute over an admin-asserted destination is a
--                        different investigation from one over a line the
--                        provider proved they held. Freezing the method means
--                        the assurance level at the time of payment is a
--                        recorded fact, not something reconstructed later from
--                        a row that has since been superseded.
--
--   verification_id      FREEZE. The method says HOW; this says WHICH EVENT —
--                        the specific challenge, its recipient, its expiry, the
--                        moment it was consumed. Null for non-OTP methods, and
--                        that absence is itself informative.
--
--   provider_user_id     FREEZE. Makes the snapshot self-proving about WHOSE
--                        destination it was, so a mis-joined escrow is
--                        detectable from the document alone.
--
--   status_at_capture    FREEZE, and note the name. The destination's CURRENT
--                        status is mutable and belongs on the row; what belongs
--                        here is the evidence that it was usable at the instant
--                        we committed to it. Naming it `status` would invite a
--                        future reader to treat a stale value as live.
--
--   captured_at          FREEZE. When the terms were fixed. Every other
--                        timestamp is only meaningful relative to it.
--
--   snapshot_version     FREEZE. A document meant to be read in 2030 must say
--                        how to read it. Without a version, the first shape
--                        change makes every historical snapshot ambiguous.
--
--   destination_fingerprint
--                        FREEZE — and this is the field that makes the document
--                        survive the database. `destination_id` is a row
--                        pointer: it resolves only while that row exists, in
--                        that table, with that id. The fingerprint is derived
--                        from the INSTRUMENT (channel + country + normalized
--                        value) and is reproducible by anyone holding the
--                        recipe. If destinations are ever archived to cold
--                        storage, re-keyed during an account merge, or copied
--                        into a successor system, the id may not survive — the
--                        fingerprint does, and it still proves this payment
--                        went to that instrument and no other.
--
--                        It also answers a question the id cannot: "were these
--                        two payments, years and systems apart, to the SAME
--                        account?" — which is exactly what a fraud review or a
--                        regulator asks.
--
--   audit_event_id       FREEZE, with a caveat stated honestly. It points at
--                        the `payout_snapshot_captured` event, and from there
--                        to the actor, the request id, and the hash-chained
--                        history around it. Strictly speaking it is derivable
--                        by querying `payout_audit_events` for this escrow — so
--                        it is a convenience pointer, not load-bearing. It
--                        earns its place because self-containment is the stated
--                        goal: a reader holding only this JSON should reach the
--                        forensic trail in one hop, without needing to know how
--                        our audit table is indexed, or that it exists.
--
--                        Written in the SAME transaction as the event, with the
--                        uuid generated first, so there is no window in which
--                        the snapshot points at an event that does not exist.
--
-- Deliberately NOT frozen:
--   destination_value    The raw string as typed. Useful for support today,
--                        irrelevant to what was paid; it stays on the row.
--   is_default           A preference at capture time, not a term of the deal.
--                        The escrow records the destination that was CHOSEN;
--                        why it was chosen is not a fact about the payment.
--   retired_at           May not exist yet, and if it comes later it belongs to
--                        the destination's story, not this payment's.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHY BOTH A FOREIGN KEY AND A JSON DOCUMENT
-- ─────────────────────────────────────────────────────────────────────────────
-- The FK gives referential integrity and stops a destination with settlement
-- history being deleted. The document gives INDEPENDENCE: reproducibility no
-- longer depends on the append-only trigger holding for the lifetime of the
-- business, nor on the row still living in the hot table. Two mechanisms, and
-- the audit survives either one failing.
--
-- `transactions.payout_destination_id` records what was ACTUALLY paid, which
-- may differ from the escrow snapshot in exactly one legitimate case: a
-- pre-migration escrow settled through the transitional path. Recording both
-- makes that case visible rather than invisible.
--
-- Rollback (safe — columns are additive and nullable):
--   ALTER TABLE public.transactions DROP COLUMN IF EXISTS payout_destination_id;
--   ALTER TABLE public.escrow       DROP COLUMN IF EXISTS payout_destination_snapshot;
--   ALTER TABLE public.escrow       DROP COLUMN IF EXISTS payout_destination_id;
-- =============================================================================

ALTER TABLE public.escrow
  ADD COLUMN IF NOT EXISTS payout_destination_id uuid
    REFERENCES public.payout_destinations(id) ON DELETE RESTRICT;

ALTER TABLE public.escrow
  ADD COLUMN IF NOT EXISTS payout_destination_snapshot jsonb;

ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS payout_destination_id uuid
    REFERENCES public.payout_destinations(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS escrow_payout_destination_idx
  ON public.escrow (payout_destination_id)
  WHERE payout_destination_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS transactions_payout_destination_idx
  ON public.transactions (payout_destination_id)
  WHERE payout_destination_id IS NOT NULL;

COMMENT ON COLUMN public.escrow.payout_destination_id IS
  'The destination frozen when this escrow was funded. Payout resolves through '
  'THIS, never through users.phone_number. NULL means a pre-migration escrow.';

COMMENT ON COLUMN public.escrow.payout_destination_snapshot IS
  'Self-contained record of the destination at funding time. Shape (v2): '
  'snapshot_version, destination_id, destination_fingerprint, provider_user_id, '
  'channel, country, normalized_destination, status_at_capture, '
  'verification_method, verified_at, verification_id, audit_event_id, '
  'captured_at. Readable without joining anything; the fingerprint keeps it '
  'meaningful even if the destination row is archived or re-keyed.';

COMMENT ON COLUMN public.transactions.payout_destination_id IS
  'The destination actually paid, stamped at B2C time. Differs from the escrow '
  'snapshot only for transitional legacy settlements — which is why both exist.';
