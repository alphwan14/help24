-- =============================================================================
-- Migration 104 — payout destinations (Phase 1: schema only, additive)
-- =============================================================================
-- NOT APPLIED. Creates tables, indexes, triggers and policies; writes no
-- existing row and changes no behaviour until the backend flag is switched on.
--
-- WHY THIS TABLE EXISTS
-- ---------------------
-- `users.phone_number` is two incompatible things at once: a contact detail
-- (edited casually, changed when someone gets a new line) and a payout
-- destination (read at settlement, handed to Daraja B2C, irreversible). A
-- contact detail should be easy to change; a payout destination should be hard
-- to change, provably controlled, and permanently recorded. One mutable column
-- cannot be both, and while it tries, money follows profile edits.
--
--   THE INVARIANT: money is never paid using mutable profile data. Every payout
--   resolves through a destination that was trusted before the money moved and
--   frozen onto the escrow before the work was done.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- THREE CONCEPTS THAT ARE OFTEN CONFLATED, AND ARE SEPARATE HERE
-- ─────────────────────────────────────────────────────────────────────────────
--
--   status              CAN this destination receive money?      pending/active/retired
--   is_default          SHOULD a new escrow choose it?           at most one, per provider
--   verification_method HOW did it come to be trusted?           otp/migration/admin/…
--
-- Collapsing any two of these is what the earlier draft of this migration did,
-- and it cost expressiveness in both directions:
--
--   * A single `active` flag meant a provider could hold only ONE usable
--     destination, so adding a bank account meant destroying their M-Pesa
--     record — deleting history to express a preference.
--   * A `legacy` STATUS meant "usable but unproven", which is not a lifecycle
--     state at all. It is a statement about PROVENANCE wearing a status's
--     clothing, and it could not distinguish an admin-asserted destination from
--     an OTP-proven one, because there was no room left to say so.
--
-- Separated, each answers exactly one question and none of them lies.
--
-- Rollback (safe — nothing references these until 107):
--   DROP TABLE IF EXISTS public.payout_destination_verifications CASCADE;
--   DROP TABLE IF EXISTS public.payout_destinations CASCADE;
--   DROP FUNCTION IF EXISTS public.fn_payout_destinations_append_only();
--   DROP FUNCTION IF EXISTS public.fn_payout_verifications_append_only();
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. The fingerprint recipe
-- ---------------------------------------------------------------------------
-- A stable, reproducible identifier for a payment INSTRUMENT.
--
-- WHAT IT IS FOR — AND EXPLICITLY NOT FOR
-- ----------------------------------------
-- Identity and audit, never security or privacy. A Kenyan MSISDN has on the
-- order of 10^8 possibilities, so an unsalted hash of one is brute-forceable in
-- seconds. This value MUST NOT be treated as a masked phone number, published,
-- or handed to an untrusted party as if it concealed anything.
--
-- It is unsalted ON PURPOSE. A pepper would make it unreproducible by anyone
-- without the pepper — including a future auditor, a regulator, or us after a
-- key rotation — which destroys the one property the fingerprint exists to
-- provide. Reproducibility is the feature; concealment is not on offer.
--
-- WHAT PARTICIPATES, AND WHY EXACTLY THESE THREE
-- ----------------------------------------------
--   normalized_destination  The instrument itself. The whole point.
--   channel                 The same digits mean different things per rail;
--                           `254…` is a wallet under mpesa and could be an
--                           account number under a future bank channel.
--   country                 Digits are only unique within a numbering plan.
--                           Without this, international expansion silently
--                           collides two different people's instruments.
--
-- WHAT MUST NEVER PARTICIPATE
-- ---------------------------
--   provider_user_id   THE IMPORTANT EXCLUSION. Including it would tie the
--                      fingerprint to the account rather than the instrument,
--                      so an account merge or a re-keyed user id would change
--                      the fingerprint of an unchanged bank account — breaking
--                      the exact guarantee this exists to give. Excluding it
--                      also makes "how many providers share this instrument?"
--                      answerable, which is a real fraud signal.
--   status, is_default, verified_at, verification_method, retired_at
--                      Lifecycle and trust. Mutable by design; folding them in
--                      would make the fingerprint change as the record ages.
--   destination_value  The raw string as typed. `0712345678` and
--                      `+254 712 345 678` are ONE instrument; normalisation
--                      exists precisely to collapse them.
--   created_at, metadata, id
--                      Row facts, not instrument facts. `id` is already the
--                      row identity — a fingerprint that included it would be
--                      a slower primary key.
--
-- STABILITY: forever, for a given version. The `pdf1:` prefix is inside the
-- hashed payload AND on the output, so a future normalisation change becomes
-- `pdf2:` — a NEW function and a NEW column. Historical fingerprints are never
-- recomputed. That is what makes a 2030 audit meaningful.
--
-- IMMUTABLE is asserted deliberately. `convert_to` with a literal encoding is
-- deterministic, but Postgres marks it STABLE, which would otherwise forbid a
-- generated column. Pinning it here is what lets the DATABASE own the value.
CREATE OR REPLACE FUNCTION public.fn_payout_fingerprint_v1(
  p_channel    text,
  p_country    text,
  p_normalized text
)
RETURNS text
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT 'pdf1:' || encode(
    sha256(convert_to(
      'pdf1|' || lower(p_channel) || '|' || upper(p_country) || '|' || p_normalized,
      'UTF8')),
    'hex')
$$;

COMMENT ON FUNCTION public.fn_payout_fingerprint_v1(text, text, text) IS
  'Instrument fingerprint v1 = sha256(pdf1|channel|country|normalized). '
  'Identity and audit only — unsalted and NOT a privacy control.';

-- ---------------------------------------------------------------------------
-- 1. Destinations
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.payout_destinations (
  id                     uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_user_id       text        NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,

  -- Present from day one so Airtel Money, Equitel, bank and international
  -- payouts are a new VALUE rather than a new table. Each channel brings its
  -- own verification story and its own idea of what `normalized_destination`
  -- means; none is assumed here.
  channel                text        NOT NULL,

  -- ISO-3166-1 alpha-2. Immutable, and part of the fingerprint: a national
  -- numbering plan is the only thing that makes a string of digits unique.
  country                text        NOT NULL DEFAULT 'KE',

  destination_value      text        NOT NULL,   -- what the human typed, verbatim
  normalized_destination text        NOT NULL,   -- the canonical form actually paid

  -- COMPUTED BY THE DATABASE, never supplied by a caller. `GENERATED ALWAYS`
  -- means an INSERT that tries to set it is refused outright, so a forged
  -- fingerprint is not a thing the application layer can produce even by
  -- accident. Verified against production before shipping.
  destination_fingerprint text
    GENERATED ALWAYS AS (
      public.fn_payout_fingerprint_v1(channel, country, normalized_destination)
    ) STORED,

  -- LIFECYCLE ONLY. Not preference, not trust level.
  --   pending  — proposed, never usable
  --   active   — trusted and usable
  --   retired  — permanently withdrawn; terminal
  status                 text        NOT NULL DEFAULT 'pending',

  -- PREFERENCE. Which ACTIVE destination a new escrow selects automatically.
  -- At most one per provider (partial unique index below). A provider may hold
  -- several active destinations; exactly one is the default.
  is_default             boolean     NOT NULL DEFAULT false,

  -- PROVENANCE — the permanent answer to "how did this become trusted?".
  --   otp        — the provider proved control of the destination itself
  --   migration  — backfilled from users.phone_number; NOBODY proved control
  --   admin      — an administrator asserted it unilaterally
  --   support    — established through an identity-checked support interaction
  --   future_kyc — reserved: verified against KYC records
  --
  -- This replaces the `legacy` status. `verified_at` records WHEN a destination
  -- was admitted to `active`; `verification_method` records ON WHAT BASIS. The
  -- two are meaningless apart and the schema refuses to store one without the
  -- other, precisely so that no future reader can mistake "has a verified_at"
  -- for "a human proved control of this line".
  verification_method    text,
  verified_at            timestamptz,
  verified_by            text,          -- actor: 'system', 'admin:<uid>', 'migration_108'
  verification_id        uuid,          -- the specific OTP challenge, when method='otp'

  retired_at             timestamptz,
  retired_reason         text,

  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  created_by_uid         text,
  metadata               jsonb       NOT NULL DEFAULT '{}'::jsonb,

  CONSTRAINT payout_destinations_channel_chk
    CHECK (channel IN ('mpesa')),

  CONSTRAINT payout_destinations_status_chk
    CHECK (status IN ('pending', 'active', 'retired')),

  CONSTRAINT payout_destinations_method_chk
    CHECK (verification_method IS NULL
        OR verification_method IN ('otp', 'migration', 'admin', 'support', 'future_kyc')),

  -- THE LOAD-BEARING PAIR. `active` is the state that says "money may go here",
  -- and it may not exist without a recorded basis and a recorded time.
  CONSTRAINT payout_destinations_active_requires_provenance_chk
    CHECK (status <> 'active' OR (verified_at IS NOT NULL AND verification_method IS NOT NULL)),

  -- Trust facts travel together or not at all. Half a provenance record is
  -- worse than none: it looks authoritative and answers nothing.
  CONSTRAINT payout_destinations_provenance_together_chk
    CHECK ((verified_at IS NULL) = (verification_method IS NULL)),

  -- An OTP claim must name the challenge that proves it. Any other method must
  -- NOT, because pointing at a challenge it did not use would fabricate proof.
  CONSTRAINT payout_destinations_otp_has_challenge_chk
    CHECK ((verification_method = 'otp') = (verification_id IS NOT NULL)),

  CONSTRAINT payout_destinations_retired_chk
    CHECK (status <> 'retired' OR retired_at IS NOT NULL),

  -- Only a usable destination may be the automatic choice. Defaulting to a
  -- pending or retired row would select a destination that cannot be paid.
  CONSTRAINT payout_destinations_default_must_be_active_chk
    CHECK (is_default = false OR status = 'active'),

  CONSTRAINT payout_destinations_normalized_nonempty_chk
    CHECK (btrim(normalized_destination) <> ''),

  CONSTRAINT payout_destinations_country_chk
    CHECK (country ~ '^[A-Z]{2}$')
);

-- Answers "which providers share this instrument?" without exposing the number
-- in the query. A real fraud signal, and only possible because provider_user_id
-- is deliberately absent from the fingerprint.
CREATE INDEX IF NOT EXISTS payout_destinations_fingerprint_idx
  ON public.payout_destinations (destination_fingerprint);

-- EXACTLY ONE DEFAULT PER PROVIDER — across all channels, not per channel.
--
-- Per-channel would not answer the question a payout actually asks. "Which
-- M-Pesa destination?" and "which bank destination?" still leaves "…and which
-- of those two?", which is the same ambiguity one level down. One default per
-- provider means resolution is total: there is never a second decision to make
-- at payout time, which is the whole requirement.
--
-- (When multi-currency payouts arrive this becomes one default per currency,
-- and that is a deliberate migration, not a surprise.)
CREATE UNIQUE INDEX IF NOT EXISTS payout_destinations_one_default
  ON public.payout_destinations (provider_user_id)
  WHERE is_default;

-- Many ACTIVE destinations are allowed — but not the same value twice for one
-- provider on one channel. Two active rows holding an identical number are
-- pure duplication: they add no capability and make an audit ambiguous about
-- which record authorised a payment.
CREATE UNIQUE INDEX IF NOT EXISTS payout_destinations_no_duplicate_active
  ON public.payout_destinations (provider_user_id, channel, normalized_destination)
  WHERE status = 'active';

-- At most one outstanding proposal per provider per channel. Bounds OTP spend
-- and stops a caller accumulating challenges to attack in parallel.
CREATE UNIQUE INDEX IF NOT EXISTS payout_destinations_one_pending
  ON public.payout_destinations (provider_user_id, channel)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS payout_destinations_provider_idx
  ON public.payout_destinations (provider_user_id, status, channel);

-- Not unique: in Kenya a household or micro-business legitimately shares one
-- M-Pesa line. This exists so a shared number is DETECTABLE for review, not
-- blocked — a hard constraint would lock out honest providers to prevent a
-- fraud we have not observed. (Confirmed against production: two accounts
-- already share a number.)
CREATE INDEX IF NOT EXISTS payout_destinations_normalized_idx
  ON public.payout_destinations (normalized_destination)
  WHERE status = 'active';

COMMENT ON TABLE public.payout_destinations IS
  'Where a provider can be paid. Append-only: changing a number is a NEW row '
  'plus retirement of the old one, never an edit — the history IS the table.';
COMMENT ON COLUMN public.payout_destinations.is_default IS
  'Preference, not permission. At most one per provider; only an active row may be it.';
COMMENT ON COLUMN public.payout_destinations.verification_method IS
  'How this destination came to be trusted. Never read verified_at without it: '
  'method=migration means nobody proved control.';

-- ---------------------------------------------------------------------------
-- 2. Verifications (OTP challenges)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.payout_destination_verifications (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  destination_id uuid        NOT NULL REFERENCES public.payout_destinations(id) ON DELETE RESTRICT,

  -- The code is NEVER stored. Only a hash computed by the backend with a
  -- server-side pepper that is not in the database, so a database disclosure
  -- yields no usable OTP and no way to compute one.
  code_hash      text        NOT NULL,

  -- Where the challenge was actually sent, frozen at send time — the question a
  -- dispute asks is "what was proven", not "what does the row say now".
  sent_to        text        NOT NULL,
  channel        text        NOT NULL,

  created_at     timestamptz NOT NULL DEFAULT now(),
  expires_at     timestamptz NOT NULL,

  -- Single use. This column IS the replay defence: consumption is a conditional
  -- update inside the RPC, so two concurrent verifications cannot both win.
  consumed_at    timestamptz,

  attempts       smallint    NOT NULL DEFAULT 0,
  max_attempts   smallint    NOT NULL DEFAULT 5,
  failed_at      timestamptz,
  failed_reason  text,

  created_by_uid text,
  metadata       jsonb       NOT NULL DEFAULT '{}'::jsonb,

  CONSTRAINT pdv_expiry_chk       CHECK (expires_at > created_at),
  CONSTRAINT pdv_attempts_chk     CHECK (attempts >= 0 AND attempts <= max_attempts),
  CONSTRAINT pdv_max_attempts_chk CHECK (max_attempts BETWEEN 1 AND 10),
  CONSTRAINT pdv_terminal_chk     CHECK (consumed_at IS NULL OR failed_at IS NULL)
);

-- ONE LIVE CHALLENGE PER DESTINATION. A resend must retire the previous one,
-- which stops an attacker holding several valid codes open and guessing at all
-- of them in parallel.
CREATE UNIQUE INDEX IF NOT EXISTS pdv_one_live_per_destination
  ON public.payout_destination_verifications (destination_id)
  WHERE consumed_at IS NULL AND failed_at IS NULL;

CREATE INDEX IF NOT EXISTS pdv_destination_idx
  ON public.payout_destination_verifications (destination_id, created_at DESC);

-- Added separately (not inline) because it points at a table created below the
-- destinations table. Guarded so the whole migration stays re-runnable:
-- `ADD CONSTRAINT` has no IF NOT EXISTS.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'payout_destinations_verification_fk'
  ) THEN
    ALTER TABLE public.payout_destinations
      ADD CONSTRAINT payout_destinations_verification_fk
      FOREIGN KEY (verification_id)
      REFERENCES public.payout_destination_verifications(id) ON DELETE RESTRICT;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Append-only enforcement
-- ---------------------------------------------------------------------------
-- "Append-only" is a promise about MEANING, not literally about UPDATE: a
-- pending row must be able to become active, and a default must be able to
-- move. What must never happen is a destination changing WHERE money goes, or
-- a trust record being un-made or re-dated.

CREATE OR REPLACE FUNCTION public.fn_payout_destinations_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'help24_payout_destination_delete_refused'
      USING ERRCODE = '42501',
            HINT = 'Retire the destination instead; payout history must remain reproducible.';
  END IF;

  -- Identity and value are frozen for the life of the row.
  IF NEW.id                     IS DISTINCT FROM OLD.id
  OR NEW.provider_user_id       IS DISTINCT FROM OLD.provider_user_id
  OR NEW.channel                IS DISTINCT FROM OLD.channel
  OR NEW.destination_value      IS DISTINCT FROM OLD.destination_value
  OR NEW.normalized_destination IS DISTINCT FROM OLD.normalized_destination
  OR NEW.created_at             IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'help24_payout_destination_immutable'
      USING ERRCODE = '42501',
            HINT = 'Changing a payout number means inserting a new destination and retiring this one.';
  END IF;

  -- Provenance is write-once. Once a destination has been trusted, that fact
  -- cannot be rewritten, re-dated, re-attributed, or upgraded from `migration`
  -- to `otp` without an actual OTP.
  IF OLD.verified_at IS NOT NULL AND (
       NEW.verified_at         IS DISTINCT FROM OLD.verified_at
    OR NEW.verification_method IS DISTINCT FROM OLD.verification_method
    OR NEW.verified_by         IS DISTINCT FROM OLD.verified_by
    OR NEW.verification_id     IS DISTINCT FROM OLD.verification_id) THEN
    RAISE EXCEPTION 'help24_payout_provenance_immutable'
      USING ERRCODE = '42501',
            HINT = 'To raise assurance, add a new destination and verify it.';
  END IF;

  -- Status moves forwards only. Reviving a retired destination is how money
  -- reaches a number its owner had already abandoned.
  IF OLD.status = 'retired' AND NEW.status <> 'retired' THEN
    RAISE EXCEPTION 'help24_payout_destination_retired_is_final'
      USING ERRCODE = '42501';
  END IF;
  IF OLD.status = 'active' AND NEW.status = 'pending' THEN
    RAISE EXCEPTION 'help24_payout_destination_status_reversal_refused'
      USING ERRCODE = '42501';
  END IF;

  -- A retiring destination cannot remain the default; the CHECK would refuse
  -- it anyway, but clearing it here means callers never have to remember.
  IF NEW.status = 'retired' THEN
    NEW.is_default := false;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payout_destinations_append_only ON public.payout_destinations;
CREATE TRIGGER trg_payout_destinations_append_only
  BEFORE UPDATE OR DELETE ON public.payout_destinations
  FOR EACH ROW EXECUTE FUNCTION public.fn_payout_destinations_append_only();

CREATE OR REPLACE FUNCTION public.fn_payout_verifications_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'help24_payout_verification_delete_refused' USING ERRCODE = '42501';
  END IF;

  IF NEW.id             IS DISTINCT FROM OLD.id
  OR NEW.destination_id IS DISTINCT FROM OLD.destination_id
  OR NEW.code_hash      IS DISTINCT FROM OLD.code_hash
  OR NEW.sent_to        IS DISTINCT FROM OLD.sent_to
  OR NEW.created_at     IS DISTINCT FROM OLD.created_at
  OR NEW.expires_at     IS DISTINCT FROM OLD.expires_at THEN
    RAISE EXCEPTION 'help24_payout_verification_immutable' USING ERRCODE = '42501';
  END IF;

  -- A consumed challenge is spent. Re-opening one is precisely an OTP replay.
  IF OLD.consumed_at IS NOT NULL THEN
    RAISE EXCEPTION 'help24_payout_verification_already_consumed' USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payout_verifications_append_only ON public.payout_destination_verifications;
CREATE TRIGGER trg_payout_verifications_append_only
  BEFORE UPDATE OR DELETE ON public.payout_destination_verifications
  FOR EACH ROW EXECUTE FUNCTION public.fn_payout_verifications_append_only();

-- ---------------------------------------------------------------------------
-- 4. RLS — the client may propose, only the server may trust
-- ---------------------------------------------------------------------------

ALTER TABLE public.payout_destinations              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payout_destination_verifications ENABLE ROW LEVEL SECURITY;

-- No policies at all for anon/authenticated on verifications: code hashes and
-- challenge state are server-only. Absent policy = denied.
REVOKE ALL ON public.payout_destination_verifications FROM anon, authenticated;
GRANT  ALL ON public.payout_destination_verifications TO service_role;

REVOKE ALL    ON public.payout_destinations FROM anon;
GRANT  SELECT, INSERT ON public.payout_destinations TO authenticated;
GRANT  ALL    ON public.payout_destinations TO service_role;

DROP POLICY IF EXISTS payout_destinations_select_own ON public.payout_destinations;
CREATE POLICY payout_destinations_select_own ON public.payout_destinations
  FOR SELECT TO authenticated
  USING (provider_user_id = (auth.jwt() ->> 'user_id'));

DROP POLICY IF EXISTS payout_destinations_insert_own_pending ON public.payout_destinations;
CREATE POLICY payout_destinations_insert_own_pending ON public.payout_destinations
  FOR INSERT TO authenticated
  WITH CHECK (
    provider_user_id = (auth.jwt() ->> 'user_id')
    AND status = 'pending'
    AND is_default = false
    AND verified_at IS NULL
    AND verification_method IS NULL
    AND verified_by IS NULL
    AND verification_id IS NULL
    AND retired_at IS NULL
  );

-- No UPDATE or DELETE policy for authenticated, by design. Activation, default
-- selection and retirement all run server-side. A client-writable `is_default`
-- would let a caller re-point their own future payouts without proving the new
-- destination — which is the same hole as a client-writable `verified`.

COMMENT ON POLICY payout_destinations_insert_own_pending ON public.payout_destinations IS
  'A provider may PROPOSE a destination. Only the backend may make one usable, '
  'and only the backend may make one the default.';
