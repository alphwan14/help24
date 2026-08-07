-- =============================================================================
-- Migration 105 — payout audit events (Phase 1: schema only, additive)
-- =============================================================================
-- NOT APPLIED. Creates one table, one trigger, one view. Writes no existing row.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHY A THIRD TABLE, WHEN TWO ALREADY LOOK LIKE THIS ONE
-- ─────────────────────────────────────────────────────────────────────────────
-- This repository already has `system_events` and `settlements`. Adding a third
-- log needs justifying, so:
--
--   system_events  is a WORK QUEUE, not a log. It carries `processed`,
--                  `retry_count`, `last_error`, `dead_letter` — columns whose
--                  entire purpose is to be UPDATED as delivery is attempted. A
--                  row that is rewritten every retry cannot be evidence of
--                  anything, and rows may be pruned once drained.
--
--   settlements    is a MONEY LEDGER. It answers "what moved, which rail, how
--                  much, to whom, what state is it in". It is append-only and
--                  correct — and it deliberately says nothing about WHY, on
--                  whose authority, from which request, or under what proof.
--
--   THIS TABLE     answers exactly what the other two do not: the FORENSIC
--                  question. Who caused this, acting as what, from which
--                  request, and what did the system believe at that instant.
--
-- The distinction that matters: the ledger reconstructs the BALANCE; the audit
-- log reconstructs the DECISION. A dispute five years from now is almost never
-- about the amount — it is about why the money went THERE.
--
-- DERIVED, NOT AUTHORITATIVE. `payout_destinations` and `escrow` remain the
-- source of truth for current state. This table explains how that state came to
-- be. If the two ever disagree, the tables are right and the disagreement is
-- itself the finding.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- TAMPER EVIDENCE — AND AN HONEST ADMISSION ABOUT TRIGGERS
-- ─────────────────────────────────────────────────────────────────────────────
-- An append-only TRIGGER stops the application from rewriting history. It does
-- not stop a superuser, and we should not pretend otherwise: migration 108's
-- own documented rollback disables a trigger to do its work. A control that the
-- operator routinely steps around is a control that an attacker with the same
-- access also steps around.
--
-- So each event also carries a hash chain. `event_hash` covers the event's own
-- immutable content AND the previous event's hash for that provider. Deleting,
-- reordering or editing any event breaks every hash after it, and the break is
-- detectable by anyone who can read the table — including someone who does not
-- trust us. The trigger prevents casual mistakes; the chain makes deliberate
-- ones evident.
--
-- Chained PER PROVIDER rather than globally: a global chain would serialise
-- every payout event in the system behind one row lock, and per-provider still
-- detects any tampering within the history that a given dispute concerns.
--
-- Rollback:
--   DROP VIEW  IF EXISTS public.payout_audit_chain_integrity;
--   DROP TABLE IF EXISTS public.payout_audit_events;
--   DROP FUNCTION IF EXISTS public.fn_payout_audit_append_only();
--   DROP FUNCTION IF EXISTS public.fn_payout_audit_seal();
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.payout_audit_events (
  event_id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- WHO the history belongs to. NOT NULL: every payout event concerns exactly
  -- one provider, and it is the chain key.
  provider_user_id      text        NOT NULL,

  -- WHAT it concerns. All nullable because the lifecycle spans stages that do
  -- not all exist yet — a `destination_created` event has no escrow, and a
  -- `payout_failed` event may have no destination if resolution refused.
  payout_destination_id uuid        REFERENCES public.payout_destinations(id) ON DELETE RESTRICT,
  escrow_id             uuid,
  transaction_id        uuid,
  verification_id       uuid        REFERENCES public.payout_destination_verifications(id) ON DELETE RESTRICT,

  -- DENORMALISED ON PURPOSE. An audit event must survive the archival,
  -- renaming or migration of everything it points at. The fingerprint in
  -- particular means the instrument stays identifiable even if the destination
  -- row is one day moved to cold storage and its id reissued.
  destination_fingerprint text,
  normalized_destination  text,
  channel                 text,

  event_type            text        NOT NULL,

  -- TWO CLOCKS, DELIBERATELY. `occurred_at` is when the thing happened in the
  -- world (a Daraja callback may report a time minutes before we hear of it);
  -- `recorded_at` is when we learned. Collapsing them loses the ability to
  -- distinguish a slow callback from a backdated record, which is precisely the
  -- kind of question a forensic review asks.
  occurred_at           timestamptz NOT NULL DEFAULT now(),
  recorded_at           timestamptz NOT NULL DEFAULT now(),

  -- WHO ACTED. `actor_type` is the class of authority; `actor_id` the identity
  -- within it. A payout caused by an admin and one caused by a scheduled sweep
  -- are different events even when every other field matches.
  actor_type            text        NOT NULL,
  actor_id              text,

  -- WHICH REQUEST. Correlates to the existing request-context middleware, so an
  -- event joins back to the access log, its latency, and any other event from
  -- the same call. This is the field that turns a list of events into a story.
  request_id            text,

  -- WHY, in words, for a human. Required for anything an operator chose to do:
  -- an unexplained manual override is indistinguishable from an attack.
  reason                text,

  metadata              jsonb       NOT NULL DEFAULT '{}'::jsonb,

  -- ── tamper evidence ──────────────────────────────────────────────────────
  -- Monotonic per provider. A gap is as informative as a broken hash.
  chain_seq             bigint      NOT NULL,
  prev_event_hash       text,
  event_hash            text        NOT NULL,

  CONSTRAINT payout_audit_actor_type_chk
    CHECK (actor_type IN ('provider', 'admin', 'support', 'system', 'processor')),

  CONSTRAINT payout_audit_event_type_chk
    CHECK (event_type IN (
      -- destination lifecycle
      'destination_created',
      'otp_requested',
      'otp_verified',
      'otp_failed',
      'default_changed',
      'destination_retired',
      -- money lifecycle
      'payout_snapshot_captured',
      'payout_initiated',
      'payout_sent_to_processor',
      'payout_completed',
      'payout_failed',
      'payout_reversed',
      -- exceptional
      'payout_refused',
      'manual_admin_override'
    )),

  -- An act of authority without a stated reason is not auditable. These are the
  -- events where a human made a choice the system would not have made alone.
  CONSTRAINT payout_audit_reason_required_chk
    CHECK (
      event_type NOT IN ('manual_admin_override', 'destination_retired', 'payout_reversed')
      OR btrim(coalesce(reason, '')) <> ''
    ),

  -- A human act names the human. `system` and `processor` legitimately have no
  -- individual behind them; provider/admin/support always do.
  CONSTRAINT payout_audit_actor_id_chk
    CHECK (actor_type IN ('system', 'processor') OR btrim(coalesce(actor_id, '')) <> ''),

  CONSTRAINT payout_audit_chain_seq_chk CHECK (chain_seq > 0)
);

-- The chain: one sequence per provider, no gaps, no reuse.
CREATE UNIQUE INDEX IF NOT EXISTS payout_audit_chain_uniq
  ON public.payout_audit_events (provider_user_id, chain_seq);

CREATE INDEX IF NOT EXISTS payout_audit_provider_time_idx
  ON public.payout_audit_events (provider_user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS payout_audit_escrow_idx
  ON public.payout_audit_events (escrow_id) WHERE escrow_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS payout_audit_transaction_idx
  ON public.payout_audit_events (transaction_id) WHERE transaction_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS payout_audit_destination_idx
  ON public.payout_audit_events (payout_destination_id) WHERE payout_destination_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS payout_audit_request_idx
  ON public.payout_audit_events (request_id) WHERE request_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS payout_audit_fingerprint_idx
  ON public.payout_audit_events (destination_fingerprint) WHERE destination_fingerprint IS NOT NULL;

COMMENT ON TABLE public.payout_audit_events IS
  'Forensic trail for payouts: who caused what, on whose authority, from which '
  'request. Not the money ledger (settlements) and not the work queue '
  '(system_events). Append-only and hash-chained per provider.';

-- ---------------------------------------------------------------------------
-- Sealing: the caller supplies facts, the database supplies the chain.
-- ---------------------------------------------------------------------------
-- chain_seq, prev_event_hash and event_hash are computed HERE, in a BEFORE
-- INSERT trigger, and any value the caller supplied is discarded. A chain the
-- application could write is a chain the application could forge.

CREATE OR REPLACE FUNCTION public.fn_payout_audit_seal()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  prev   public.payout_audit_events%ROWTYPE;
  body   text;
BEGIN
  -- Lock this provider's tail so two concurrent events cannot claim one seq.
  SELECT * INTO prev
    FROM public.payout_audit_events
   WHERE provider_user_id = NEW.provider_user_id
   ORDER BY chain_seq DESC
   LIMIT 1
     FOR UPDATE;

  NEW.chain_seq       := COALESCE(prev.chain_seq, 0) + 1;
  NEW.prev_event_hash := prev.event_hash;   -- NULL for the first event
  NEW.recorded_at     := now();

  -- Every immutable field participates. Anything omitted here could be altered
  -- later without breaking the chain, which would make the chain a decoration.
  body := concat_ws('|',
    'pae1',
    NEW.event_id::text,
    NEW.provider_user_id,
    coalesce(NEW.payout_destination_id::text, ''),
    coalesce(NEW.escrow_id::text, ''),
    coalesce(NEW.transaction_id::text, ''),
    coalesce(NEW.verification_id::text, ''),
    coalesce(NEW.destination_fingerprint, ''),
    coalesce(NEW.normalized_destination, ''),
    coalesce(NEW.channel, ''),
    NEW.event_type,
    to_char(NEW.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.USOF'),
    NEW.actor_type,
    coalesce(NEW.actor_id, ''),
    coalesce(NEW.request_id, ''),
    coalesce(NEW.reason, ''),
    NEW.metadata::text,
    NEW.chain_seq::text,
    coalesce(NEW.prev_event_hash, '')
  );

  NEW.event_hash := 'pae1:' || encode(sha256(convert_to(body, 'UTF8')), 'hex');
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payout_audit_seal
  BEFORE INSERT ON public.payout_audit_events
  FOR EACH ROW EXECUTE FUNCTION public.fn_payout_audit_seal();

CREATE OR REPLACE FUNCTION public.fn_payout_audit_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $$
BEGIN
  RAISE EXCEPTION 'help24_payout_audit_is_append_only'
    USING ERRCODE = '42501',
          HINT = 'Audit events are never updated or deleted. Record a new event instead.';
END;
$$;

CREATE TRIGGER trg_payout_audit_append_only
  BEFORE UPDATE OR DELETE ON public.payout_audit_events
  FOR EACH ROW EXECUTE FUNCTION public.fn_payout_audit_append_only();

-- ---------------------------------------------------------------------------
-- Integrity check — runnable by anyone, including someone who distrusts us.
-- ---------------------------------------------------------------------------
-- Recomputes every hash from the stored fields and compares. A row where
-- `hash_ok` is false has been altered; a row where `link_ok` is false has had
-- something before it removed or reordered.

CREATE OR REPLACE VIEW public.payout_audit_chain_integrity AS
SELECT
  e.event_id,
  e.provider_user_id,
  e.chain_seq,
  e.event_type,
  e.occurred_at,
  (e.event_hash = 'pae1:' || encode(sha256(convert_to(concat_ws('|',
      'pae1', e.event_id::text, e.provider_user_id,
      coalesce(e.payout_destination_id::text, ''),
      coalesce(e.escrow_id::text, ''),
      coalesce(e.transaction_id::text, ''),
      coalesce(e.verification_id::text, ''),
      coalesce(e.destination_fingerprint, ''),
      coalesce(e.normalized_destination, ''),
      coalesce(e.channel, ''),
      e.event_type,
      to_char(e.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.USOF'),
      e.actor_type, coalesce(e.actor_id, ''), coalesce(e.request_id, ''),
      coalesce(e.reason, ''), e.metadata::text, e.chain_seq::text,
      coalesce(e.prev_event_hash, '')
    ), 'UTF8')), 'hex')) AS hash_ok,
  (e.prev_event_hash IS NOT DISTINCT FROM
     lag(e.event_hash) OVER (PARTITION BY e.provider_user_id ORDER BY e.chain_seq)
  ) AS link_ok
FROM public.payout_audit_events e;

COMMENT ON VIEW public.payout_audit_chain_integrity IS
  'Recomputes every audit hash. hash_ok=false means a row was edited; '
  'link_ok=false means a row was removed or reordered. Expect all true.';

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------
ALTER TABLE public.payout_audit_events ENABLE ROW LEVEL SECURITY;

-- Server-only. Not even the provider reads this directly: it carries actor
-- identities and internal reasoning, and a "who touched my account" surface is
-- a product decision to make deliberately, not a side effect of a grant.
REVOKE ALL ON public.payout_audit_events           FROM anon, authenticated;
REVOKE ALL ON public.payout_audit_chain_integrity  FROM anon, authenticated;
GRANT  SELECT, INSERT ON public.payout_audit_events          TO service_role;
GRANT  SELECT          ON public.payout_audit_chain_integrity TO service_role;

-- Note the absence of UPDATE and DELETE for service_role as well. The triggers
-- refuse them anyway; withholding the grant means the intent is visible in the
-- catalog and not only in a function body.
