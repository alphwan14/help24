-- =============================================================================
-- 114 — Trust & Safety, part 1 of 3: reports, restrictions, and the ledger
-- =============================================================================
-- NOT APPLIED. Written 2026-09-27 against the LIVE catalog of
-- `taohzhnvaitrpxcyjflq` (read-only introspection), and exercised end to end on
-- a local PostgreSQL 17.6 replica of that catalog — see
-- supabase/tests/trust-safety/README.md.
--
-- Apply order: 114 → 115 → (backend + dashboard deploy) → 116 → app release.
-- 114 and 115 change NO existing marketplace behaviour. 116 is the one that
-- starts refusing writes from restricted accounts.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHAT EXISTED BEFORE THIS, MEASURED ON PRODUCTION
-- ─────────────────────────────────────────────────────────────────────────────
--   • `user_reports` (migration 084): chat-only, five reasons, statuses
--     open/reviewed/dismissed, INSERT-only for the reporter. NOTHING READ IT —
--     no dashboard page, no backend route. 0 rows.
--   • `users.is_banned`: flipped by a one-click dashboard toggle with no reason,
--     no actor and no history, and enforced NOWHERE — not by the backend, not by
--     RLS, not by the app. 0 users banned.
--
-- This migration generalises the first and replaces the second with something
-- that can answer "who decided this, why, and when?".
--
-- ─────────────────────────────────────────────────────────────────────────────
-- THE THREE THINGS A MODERATION RECORD MUST KEEP APART
-- ─────────────────────────────────────────────────────────────────────────────
--   user_reports          THE ALLEGATION. What someone said happened, frozen as
--                         they said it, with a snapshot of the content they were
--                         looking at. Never edited, never deleted.
--   account_restrictions  THE STATE. Which sanctions are in force. Rows are
--                         never deleted; ending one is recorded, once.
--   moderation_actions    THE DECISIONS. Every act of authority: who, in what
--                         role, why, what the account looked like before and
--                         after. Append-only and hash-chained per user.
--
-- A report is not proof, and nothing here treats it as one: no report changes
-- an account's state. Only an admin decision does, and every such decision is a
-- ledger row written in the SAME transaction as the change it describes
-- (migration 115). Direct writes to all three tables are revoked even from
-- `service_role`, so "change the state without recording it" is not an
-- operation this database offers.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHY NONE OF THIS LIVES ON `public.users`
-- ─────────────────────────────────────────────────────────────────────────────
-- `users` is SELECT-able by `anon` (logged-out browsing depends on it — see
-- 103). Any moderation column added there is public the moment it exists: a
-- suspension reason would be readable by anyone holding the publishable key.
-- So state lives in RLS-locked tables, and a person reads their OWN status
-- through `my_account_status()`, which returns only user-safe fields.
--
-- `users.is_banned` is KEPT, as a mirror of "has an active ban", because the
-- dashboard and any SQL a person writes still read it. It can now change only
-- inside the moderation functions (see §4), so the mirror cannot drift.
--
-- Rollback (nothing else depends on these objects until 115 exists; roll 115
-- back first):
--   DROP VIEW  IF EXISTS public.moderation_account_state, public.moderation_audit_integrity;
--   DROP TABLE IF EXISTS public.moderation_actions, public.account_restrictions;
--   DROP TRIGGER IF EXISTS trg_users_is_banned_guard ON public.users;
--   DROP TRIGGER IF EXISTS trg_user_reports_prepare ON public.user_reports;
--   DROP TRIGGER IF EXISTS trg_user_reports_guard ON public.user_reports;
--   DROP TRIGGER IF EXISTS trg_user_reports_no_truncate ON public.user_reports;
--   DROP FUNCTION IF EXISTS public.my_account_status(), public.moderation_denial(text, text),
--     public.moderation_capabilities(), public.moderation_state_json(text),
--     public.moderation_active_kinds(text), public.moderation_report_categories(text),
--     public.moderation_initial_severity(text, text, text), public.moderation_caller_is_trusted(),
--     public.moderation_action_hash_body(public.moderation_actions),
--     public.fn_moderation_actions_seal(), public.fn_moderation_history_immutable(),
--     public.fn_account_restrictions_guard(), public.fn_users_is_banned_guard(),
--     public.fn_user_reports_prepare(), public.fn_user_reports_guard();
--   (user_reports keeps its new columns; they are nullable/defaulted and harmless.)
-- =============================================================================

BEGIN;

-- =============================================================================
-- §0  Who is calling
-- =============================================================================
-- The one definition of a TRUSTED caller, used by every trigger and function
-- below. Trusted means the backend (PostgREST with the service_role key) or a
-- direct owner connection (SQL editor, migrations). Everyone else — `anon` and
-- `authenticated`, i.e. anything holding the key that ships inside the app —
-- is untrusted.
--
-- Read from the JWT claims PostgREST sets per request, not from current_user:
-- inside a SECURITY DEFINER function current_user is the function's OWNER, so
-- it would call every caller trusted.
CREATE OR REPLACE FUNCTION public.moderation_caller_is_trusted()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'role'
         = 'service_role' THEN true
    WHEN coalesce(coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'role', '') = ''
         AND session_user IN ('postgres', 'supabase_admin') THEN true
    ELSE false
  END
$$;

-- =============================================================================
-- §1  user_reports — from "report a chat partner" to "report anything"
-- =============================================================================

-- The old vocabularies are replaced below, after existing rows are translated.
ALTER TABLE public.user_reports DROP CONSTRAINT IF EXISTS user_reports_reason_check;
ALTER TABLE public.user_reports DROP CONSTRAINT IF EXISTS user_reports_status_check;

ALTER TABLE public.user_reports
  -- WHAT was reported. The reported PERSON is derived from this (§6), never
  -- taken from the client.
  ADD COLUMN IF NOT EXISTS target_type       text,
  ADD COLUMN IF NOT EXISTS target_id         text,
  -- Context, like the existing chat_id / post_id / message_id. No FK: an
  -- application can be withdrawn and the report must survive that.
  ADD COLUMN IF NOT EXISTS application_id    uuid,
  -- The content AS THE REPORTER SAW IT. A reported listing can be edited and a
  -- reported message deleted a minute later; the allegation must still be
  -- about what was actually there.
  ADD COLUMN IF NOT EXISTS target_snapshot   jsonb       NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS severity          text        NOT NULL DEFAULT 'medium',
  -- Screenshot references into the private evidence bucket. Registered only
  -- through the backend, which checks each path is the reporter's own upload.
  ADD COLUMN IF NOT EXISTS evidence          jsonb       NOT NULL DEFAULT '[]'::jsonb,
  -- 'api' = POST /reports (validated, current app). 'app_direct' = the
  -- PostgREST insert the shipped chat sheet still performs.
  ADD COLUMN IF NOT EXISTS source            text        NOT NULL DEFAULT 'app_direct',
  -- Triage state. Written only by the migration-115 functions.
  ADD COLUMN IF NOT EXISTS assigned_admin_id uuid,
  ADD COLUMN IF NOT EXISTS assigned_at       timestamptz,
  ADD COLUMN IF NOT EXISTS updated_at        timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS resolved_at       timestamptz,
  ADD COLUMN IF NOT EXISTS resolved_by       uuid,
  ADD COLUMN IF NOT EXISTS resolution        text,
  ADD COLUMN IF NOT EXISTS resolution_reason text,
  -- So the queue can be ordered "most serious first, oldest first" by the
  -- API (PostgREST cannot ORDER BY a CASE), and indexed that way.
  ADD COLUMN IF NOT EXISTS severity_rank     smallint GENERATED ALWAYS AS (
    CASE severity WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END) STORED;

-- Translate any existing rows (there were 0 on 2026-09-27; written generally
-- so a report filed between now and the apply is carried, not stranded).
UPDATE public.user_reports SET
  status      = CASE status WHEN 'open' THEN 'new' WHEN 'reviewed' THEN 'resolved' ELSE status END,
  target_type = coalesce(target_type, CASE WHEN message_id IS NOT NULL THEN 'message' ELSE 'user' END),
  target_id   = coalesce(target_id, CASE WHEN message_id IS NOT NULL THEN message_id::text ELSE reported_user_id END);

UPDATE public.user_reports SET
  resolved_at       = coalesce(resolved_at, created_at),
  resolution        = coalesce(resolution, CASE status WHEN 'dismissed' THEN 'dismissed' ELSE 'no_action' END),
  resolution_reason = coalesce(resolution_reason, 'Closed before the Trust & Safety system existed.')
WHERE status IN ('resolved', 'dismissed');

ALTER TABLE public.user_reports ALTER COLUMN status SET DEFAULT 'new';
-- NOT NULL is safe for the shipped client, which sends neither column: BEFORE
-- triggers run before constraints are checked, and §6 fills both.
ALTER TABLE public.user_reports ALTER COLUMN target_type SET NOT NULL;
ALTER TABLE public.user_reports ALTER COLUMN target_id   SET NOT NULL;

ALTER TABLE public.user_reports
  DROP CONSTRAINT IF EXISTS user_reports_target_type_check,
  DROP CONSTRAINT IF EXISTS user_reports_severity_check,
  DROP CONSTRAINT IF EXISTS user_reports_source_check,
  DROP CONSTRAINT IF EXISTS user_reports_resolution_check,
  DROP CONSTRAINT IF EXISTS user_reports_details_length,
  DROP CONSTRAINT IF EXISTS user_reports_evidence_shape,
  DROP CONSTRAINT IF EXISTS user_reports_terminal_consistent,
  DROP CONSTRAINT IF EXISTS user_reports_resolution_matches_status,
  DROP CONSTRAINT IF EXISTS user_reports_assignment_consistent;

ALTER TABLE public.user_reports
  -- The first five are 084's values, so the shipped app keeps working.
  ADD CONSTRAINT user_reports_reason_check CHECK (reason IN (
    'spam', 'scam_or_fraud', 'inappropriate_content', 'harassment', 'other',
    'suspicious_activity', 'illegal_activity', 'threats', 'impersonation',
    'misleading_listing', 'payment_issue', 'unsafe_behavior')),
  ADD CONSTRAINT user_reports_status_check CHECK (status IN (
    'new', 'under_review', 'action_required', 'resolved', 'dismissed')),
  ADD CONSTRAINT user_reports_target_type_check CHECK (target_type IN (
    'user', 'post', 'application', 'message')),
  ADD CONSTRAINT user_reports_severity_check CHECK (severity IN (
    'low', 'medium', 'high', 'critical')),
  ADD CONSTRAINT user_reports_source_check CHECK (source IN ('api', 'app_direct')),
  ADD CONSTRAINT user_reports_resolution_check CHECK (
    resolution IS NULL OR resolution IN ('action_taken', 'no_action', 'dismissed')),
  ADD CONSTRAINT user_reports_details_length CHECK (char_length(details) <= 2000),
  ADD CONSTRAINT user_reports_evidence_shape CHECK (
    jsonb_typeof(evidence) = 'array' AND jsonb_array_length(evidence) <= 5),
  -- A closed report says when, and how. An open one says neither.
  ADD CONSTRAINT user_reports_terminal_consistent CHECK (
    (status IN ('resolved', 'dismissed')) = (resolved_at IS NOT NULL AND resolution IS NOT NULL)),
  ADD CONSTRAINT user_reports_resolution_matches_status CHECK (
    resolution IS NULL OR ((status = 'dismissed') = (resolution = 'dismissed'))),
  ADD CONSTRAINT user_reports_assignment_consistent CHECK (
    (assigned_admin_id IS NULL) = (assigned_at IS NULL));

-- ON DELETE CASCADE deleted the evidence along with the person. Evidence
-- outlives accounts, the same way disputes and payout_destinations do.
ALTER TABLE public.user_reports
  DROP CONSTRAINT IF EXISTS user_reports_reporter_id_fkey,
  DROP CONSTRAINT IF EXISTS user_reports_reported_user_id_fkey,
  DROP CONSTRAINT IF EXISTS user_reports_assigned_admin_fkey,
  DROP CONSTRAINT IF EXISTS user_reports_resolved_by_fkey;
ALTER TABLE public.user_reports
  ADD CONSTRAINT user_reports_reporter_id_fkey
    FOREIGN KEY (reporter_id) REFERENCES public.users(id) ON DELETE RESTRICT,
  ADD CONSTRAINT user_reports_reported_user_id_fkey
    FOREIGN KEY (reported_user_id) REFERENCES public.users(id) ON DELETE RESTRICT,
  ADD CONSTRAINT user_reports_assigned_admin_fkey
    FOREIGN KEY (assigned_admin_id) REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  ADD CONSTRAINT user_reports_resolved_by_fkey
    FOREIGN KEY (resolved_by) REFERENCES public.admin_users(id) ON DELETE RESTRICT;

-- ONE OPEN REPORT PER PERSON PER THING. Different people reporting the same
-- listing is signal and is always accepted; the same person pressing Report
-- five times is not five reports.
CREATE UNIQUE INDEX IF NOT EXISTS user_reports_one_open_per_target
  ON public.user_reports (reporter_id, target_type, target_id)
  WHERE status IN ('new', 'under_review', 'action_required');

CREATE INDEX IF NOT EXISTS idx_user_reports_reporter
  ON public.user_reports (reporter_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_user_reports_target
  ON public.user_reports (target_type, target_id);
CREATE INDEX IF NOT EXISTS idx_user_reports_open_severity
  ON public.user_reports (severity_rank DESC, created_at)
  WHERE status IN ('new', 'under_review', 'action_required');
CREATE INDEX IF NOT EXISTS idx_user_reports_open_assignee
  ON public.user_reports (assigned_admin_id)
  WHERE status IN ('new', 'under_review', 'action_required');
CREATE INDEX IF NOT EXISTS idx_user_reports_reason
  ON public.user_reports (reason, created_at DESC);

-- =============================================================================
-- §2  account_restrictions — the sanctions in force
-- =============================================================================
-- One row per sanction. A row is never deleted and its terms never change;
-- the only permitted update is recording that it was lifted, once. Expiry is
-- computed from `ends_at` at read time, so an expired suspension needs no job
-- to "end" it and cannot outlive its term because a sweep did not run.
--
--   suspension   everything that creates a commitment or reaches another
--                person, for a stated period. `ends_at` REQUIRED.
--   ban          the same, with no end. `ends_at` must be NULL. Reversible
--                only by an admin lifting it — never by deleting the account.
--   messaging    messaging only. Optional end.
--   marketplace  new listings, applications, hiring, payments, promotions.
--                Optional end.
--
-- What each kind blocks is decided in ONE place: moderation_denial() (§5).

CREATE TABLE IF NOT EXISTS public.account_restrictions (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           text        NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  kind              text        NOT NULL,
  -- SHOWN TO THE USER. The admin writes it knowing that; private reasoning
  -- goes in moderation_actions.internal_note, which is never shown.
  reason            text        NOT NULL,
  starts_at         timestamptz NOT NULL DEFAULT now(),
  ends_at           timestamptz,
  report_id         uuid        REFERENCES public.user_reports(id) ON DELETE RESTRICT,
  created_by        uuid        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  created_by_system boolean     NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now(),
  lifted_at         timestamptz,
  lifted_by         uuid        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  lift_reason       text,

  CONSTRAINT account_restrictions_kind_check
    CHECK (kind IN ('suspension', 'ban', 'messaging', 'marketplace')),
  CONSTRAINT account_restrictions_reason_check
    CHECK (btrim(reason) <> '' AND char_length(reason) <= 1000),
  -- A human act names the human; only the legacy import (§7) is the system's.
  CONSTRAINT account_restrictions_actor_check
    CHECK (created_by_system = (created_by IS NULL)),
  CONSTRAINT account_restrictions_suspension_has_end
    CHECK (kind <> 'suspension' OR ends_at IS NOT NULL),
  CONSTRAINT account_restrictions_ban_has_no_end
    CHECK (kind <> 'ban' OR ends_at IS NULL),
  CONSTRAINT account_restrictions_window_check
    CHECK (ends_at IS NULL OR ends_at > starts_at),
  CONSTRAINT account_restrictions_lift_check
    CHECK ((lifted_at IS NULL) = (lift_reason IS NULL)
           AND (lifted_by IS NULL OR lifted_at IS NOT NULL)
           AND (lift_reason IS NULL OR btrim(lift_reason) <> ''))
);

CREATE INDEX IF NOT EXISTS idx_account_restrictions_user_unlifted
  ON public.account_restrictions (user_id) WHERE lifted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_account_restrictions_user_history
  ON public.account_restrictions (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_account_restrictions_kind_unlifted
  ON public.account_restrictions (kind, ends_at) WHERE lifted_at IS NULL;

COMMENT ON TABLE public.account_restrictions IS
  'Sanctions in force (suspension/ban/messaging/marketplace). Never deleted; the only '
  'permitted update records a lift, once. Written only by the migration-115 functions. '
  '`reason` is shown to the restricted user.';

-- =============================================================================
-- §3  moderation_actions — the ledger of decisions
-- =============================================================================
-- Every act of authority, including the ones that change nothing (a dismissal,
-- a note) — "we looked and decided not to act" is a decision too, and the one
-- most often questioned later.
--
-- TAMPER EVIDENCE, stated honestly (the same reasoning as payout_audit_events,
-- migration 105): the append-only trigger stops the application; it does not
-- stop a database owner. Each row therefore also carries a hash over its own
-- content and the previous row's hash for the same user. Editing, removing or
-- reordering a row breaks the chain for everything after it, and
-- moderation_audit_integrity recomputes it for anyone who wants to check.
-- (Removing the NEWEST row of a chain leaves no break; that residual gap is
-- why the rows are also mirrored into restriction state that has its own guard.)

CREATE TABLE IF NOT EXISTS public.moderation_actions (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- The chain key. Every decision concerns exactly one person.
  target_user_id  text        NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  action_type     text        NOT NULL,
  actor_type      text        NOT NULL DEFAULT 'admin',
  admin_id        uuid        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  -- SNAPSHOT of the admin at the moment of the act. A role changes later and
  -- an address can be reassigned; the question "was this person ALLOWED to do
  -- this, then?" needs the answer as it stood then.
  admin_email     text,
  admin_role      text,
  report_id       uuid        REFERENCES public.user_reports(id) ON DELETE RESTRICT,
  restriction_id  uuid        REFERENCES public.account_restrictions(id) ON DELETE RESTRICT,
  content_type    text,
  content_id      text,
  -- The stated reason. For a sanction this is the reason the user is shown.
  reason          text        NOT NULL,
  -- Admin-only. Never returned to the affected user or to a reporter.
  internal_note   text,
  previous_state  jsonb       NOT NULL DEFAULT '{}'::jsonb,
  new_state       jsonb       NOT NULL DEFAULT '{}'::jsonb,
  metadata        jsonb       NOT NULL DEFAULT '{}'::jsonb,
  -- Correlates with the backend access log (X-Request-Id).
  request_id      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  -- Computed by the seal trigger; caller-supplied values are discarded.
  chain_seq       bigint      NOT NULL DEFAULT 0,
  prev_hash       text,
  row_hash        text        NOT NULL DEFAULT '',

  CONSTRAINT moderation_actions_type_check CHECK (action_type IN (
    'report_triaged', 'report_reopened', 'report_resolved', 'report_dismissed',
    'note_added',
    'warning_issued', 'suspension_applied', 'ban_applied',
    'messaging_restricted', 'marketplace_restricted', 'restriction_lifted',
    'content_removed', 'content_restored',
    'legacy_ban_imported')),
  CONSTRAINT moderation_actions_actor_check CHECK (actor_type IN ('admin', 'system')),
  CONSTRAINT moderation_actions_actor_present CHECK (
    (actor_type = 'admin') = (admin_id IS NOT NULL)),
  CONSTRAINT moderation_actions_admin_snapshot CHECK (
    actor_type <> 'admin' OR (admin_email IS NOT NULL AND admin_role IS NOT NULL)),
  CONSTRAINT moderation_actions_content_check CHECK (
    (content_type IS NULL) = (content_id IS NULL)
    AND (content_type IS NULL OR content_type IN ('post', 'message'))),
  CONSTRAINT moderation_actions_content_required CHECK (
    action_type NOT IN ('content_removed', 'content_restored') OR content_type IS NOT NULL),
  CONSTRAINT moderation_actions_restriction_required CHECK (
    action_type NOT IN ('suspension_applied', 'ban_applied', 'messaging_restricted',
                        'marketplace_restricted', 'restriction_lifted', 'legacy_ban_imported')
    OR restriction_id IS NOT NULL),
  CONSTRAINT moderation_actions_report_required CHECK (
    action_type NOT IN ('report_triaged', 'report_reopened', 'report_resolved', 'report_dismissed')
    OR report_id IS NOT NULL),
  CONSTRAINT moderation_actions_note_required CHECK (
    action_type <> 'note_added' OR btrim(coalesce(internal_note, '')) <> ''),
  -- An act of authority without a stated reason is not auditable.
  CONSTRAINT moderation_actions_reason_check CHECK (
    btrim(reason) <> '' AND char_length(reason) <= 2000),
  CONSTRAINT moderation_actions_note_length CHECK (
    internal_note IS NULL OR char_length(internal_note) <= 4000),
  CONSTRAINT moderation_actions_chain_seq_check CHECK (chain_seq > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS moderation_actions_chain_uniq
  ON public.moderation_actions (target_user_id, chain_seq);
CREATE INDEX IF NOT EXISTS idx_moderation_actions_user_time
  ON public.moderation_actions (target_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_moderation_actions_report
  ON public.moderation_actions (report_id) WHERE report_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_moderation_actions_restriction
  ON public.moderation_actions (restriction_id) WHERE restriction_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_moderation_actions_admin_time
  ON public.moderation_actions (admin_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_moderation_actions_type_time
  ON public.moderation_actions (action_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_moderation_actions_time
  ON public.moderation_actions (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_moderation_actions_content
  ON public.moderation_actions (content_type, content_id) WHERE content_id IS NOT NULL;

COMMENT ON TABLE public.moderation_actions IS
  'The moderation ledger: every admin decision, with the actor snapshot, the stated reason, '
  'an internal note, and the account state before/after. Append-only, hash-chained per '
  'target user (see moderation_audit_integrity). Written only by the migration-115 functions.';

-- The ONE serialisation of a row for hashing, shared by the seal trigger and
-- the integrity view so the two can never disagree about what was signed.
CREATE OR REPLACE FUNCTION public.moderation_action_hash_body(a public.moderation_actions)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT concat_ws('|',
    'mda1',
    a.id::text,
    a.target_user_id,
    a.action_type,
    a.actor_type,
    coalesce(a.admin_id::text, ''),
    coalesce(a.admin_email, ''),
    coalesce(a.admin_role, ''),
    coalesce(a.report_id::text, ''),
    coalesce(a.restriction_id::text, ''),
    coalesce(a.content_type, ''),
    coalesce(a.content_id, ''),
    a.reason,
    coalesce(a.internal_note, ''),
    a.previous_state::text,
    a.new_state::text,
    a.metadata::text,
    coalesce(a.request_id, ''),
    to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
    a.chain_seq::text,
    coalesce(a.prev_hash, ''))
$$;

-- The database supplies the chain; the caller supplies facts. A chain the
-- application could write is a chain the application could forge.
CREATE OR REPLACE FUNCTION public.fn_moderation_actions_seal()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_prev public.moderation_actions%ROWTYPE;
BEGIN
  -- Serialise per user. A row lock on the previous tail cannot cover the FIRST
  -- action for a user (there is no row to lock), and two first-actions racing
  -- would both claim seq 1; the advisory lock covers that case too.
  PERFORM pg_advisory_xact_lock(hashtextextended('help24.moderation_actions:' || NEW.target_user_id, 0));

  SELECT * INTO v_prev
    FROM public.moderation_actions
   WHERE target_user_id = NEW.target_user_id
   ORDER BY chain_seq DESC
   LIMIT 1;

  NEW.chain_seq  := coalesce(v_prev.chain_seq, 0) + 1;
  NEW.prev_hash  := v_prev.row_hash;       -- NULL for a user's first action
  NEW.created_at := now();
  NEW.row_hash   := 'mda1:' || encode(sha256(convert_to(public.moderation_action_hash_body(NEW), 'UTF8')), 'hex');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_moderation_actions_seal ON public.moderation_actions;
CREATE TRIGGER trg_moderation_actions_seal
  BEFORE INSERT ON public.moderation_actions
  FOR EACH ROW EXECUTE FUNCTION public.fn_moderation_actions_seal();

-- Shared by every history table here: rows are corrected by writing a NEW row
-- that says so, never by editing the old one.
CREATE OR REPLACE FUNCTION public.fn_moderation_history_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'HELP24_MODERATION_HISTORY_IMMUTABLE: % on %.% is not permitted',
    TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = '42501',
          HINT = 'Moderation history is append-only. Record a new action instead.';
END;
$$;

DROP TRIGGER IF EXISTS trg_moderation_actions_immutable ON public.moderation_actions;
CREATE TRIGGER trg_moderation_actions_immutable
  BEFORE UPDATE OR DELETE ON public.moderation_actions
  FOR EACH ROW EXECUTE FUNCTION public.fn_moderation_history_immutable();

-- TRUNCATE bypasses row triggers entirely; it needs its own statement trigger.
DROP TRIGGER IF EXISTS trg_moderation_actions_no_truncate ON public.moderation_actions;
CREATE TRIGGER trg_moderation_actions_no_truncate
  BEFORE TRUNCATE ON public.moderation_actions
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_moderation_history_immutable();

-- Integrity, recomputable by anyone who can read the table.
--   hash_ok = false  a row's content was edited after it was written
--   link_ok = false  a row before it was removed, inserted or reordered
--   seq_ok  = false  the sequence has a gap (a row was removed)
CREATE OR REPLACE VIEW public.moderation_audit_integrity
WITH (security_invoker = true) AS
SELECT
  a.id,
  a.target_user_id,
  a.chain_seq,
  a.action_type,
  a.created_at,
  a.row_hash = 'mda1:' || encode(sha256(convert_to(public.moderation_action_hash_body(a), 'UTF8')), 'hex') AS hash_ok,
  a.prev_hash IS NOT DISTINCT FROM
    lag(a.row_hash) OVER (PARTITION BY a.target_user_id ORDER BY a.chain_seq) AS link_ok,
  a.chain_seq = row_number() OVER (PARTITION BY a.target_user_id ORDER BY a.chain_seq) AS seq_ok
FROM public.moderation_actions a;

COMMENT ON VIEW public.moderation_audit_integrity IS
  'Recomputes every moderation ledger hash. Expect hash_ok, link_ok and seq_ok all true.';

-- account_restrictions: terms are immutable, a lift is recorded once, nothing
-- is deleted.
CREATE OR REPLACE FUNCTION public.fn_account_restrictions_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'HELP24_MODERATION_HISTORY_IMMUTABLE: restrictions are never deleted — lift them instead'
      USING ERRCODE = '42501';
  END IF;

  IF OLD.lifted_at IS NOT NULL THEN
    RAISE EXCEPTION 'HELP24_MODERATION_HISTORY_IMMUTABLE: restriction % was already lifted', OLD.id
      USING ERRCODE = '42501';
  END IF;

  IF NEW.lifted_at IS NULL THEN
    RAISE EXCEPTION 'HELP24_MODERATION_HISTORY_IMMUTABLE: the only permitted change to a restriction is lifting it'
      USING ERRCODE = '42501';
  END IF;

  IF (NEW.id, NEW.user_id, NEW.kind, NEW.reason, NEW.starts_at, NEW.ends_at, NEW.report_id,
      NEW.created_by, NEW.created_by_system, NEW.created_at)
     IS DISTINCT FROM
     (OLD.id, OLD.user_id, OLD.kind, OLD.reason, OLD.starts_at, OLD.ends_at, OLD.report_id,
      OLD.created_by, OLD.created_by_system, OLD.created_at) THEN
    RAISE EXCEPTION 'HELP24_MODERATION_HISTORY_IMMUTABLE: the terms of a restriction cannot be edited'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_account_restrictions_guard ON public.account_restrictions;
CREATE TRIGGER trg_account_restrictions_guard
  BEFORE UPDATE OR DELETE ON public.account_restrictions
  FOR EACH ROW EXECUTE FUNCTION public.fn_account_restrictions_guard();

DROP TRIGGER IF EXISTS trg_account_restrictions_no_truncate ON public.account_restrictions;
CREATE TRIGGER trg_account_restrictions_no_truncate
  BEFORE TRUNCATE ON public.account_restrictions
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_moderation_history_immutable();

-- =============================================================================
-- §4  users.is_banned — a mirror that cannot drift
-- =============================================================================
-- Before this, `setUserBanned` (admin dashboard) wrote the column directly with
-- service_role: no reason, no actor, no history. The flag now changes only
-- inside the migration-115 functions, which set `help24.moderation_write`
-- for the length of their own transaction. A direct write — from the old
-- dashboard build, a script, or the SQL editor — is refused.
--
-- Not a defence against a database owner, who can set the flag by hand. It is
-- a defence against the thing that actually happens: someone flipping a
-- column because it is there, with nothing written down.
CREATE OR REPLACE FUNCTION public.fn_users_is_banned_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.is_banned IS DISTINCT FROM OLD.is_banned
     AND coalesce(current_setting('help24.moderation_write', true), '') <> 'on' THEN
    RAISE EXCEPTION 'HELP24_MODERATION_WRITE_REQUIRED: users.is_banned mirrors account_restrictions and changes only through the moderation functions'
      USING ERRCODE = '42501',
            HINT = 'Use moderation_apply_sanction / moderation_lift_restriction (migration 115).';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_is_banned_guard ON public.users;
CREATE TRIGGER trg_users_is_banned_guard
  BEFORE UPDATE OF is_banned ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.fn_users_is_banned_guard();

-- =============================================================================
-- §5  Reading the state: one capability map, one status answer
-- =============================================================================

-- Every capability a restriction can remove. The backend's @Restrict(...)
-- decorator names these, and the app's gates read them back from
-- my_account_status() — neither keeps its own copy of the mapping.
CREATE OR REPLACE FUNCTION public.moderation_capabilities()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY['post', 'apply', 'hire', 'pay', 'message', 'promote', 'review', 'complete', 'payout_config']
$$;

-- Kinds of restriction in force for a user right now. Expiry is a read-time
-- fact: nothing has to run for a suspension to end.
CREATE OR REPLACE FUNCTION public.moderation_active_kinds(p_user_id text)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(array_agg(DISTINCT r.kind), '{}'::text[])
    FROM public.account_restrictions r
   WHERE r.user_id = p_user_id
     AND r.lifted_at IS NULL
     AND r.starts_at <= now()
     AND (r.ends_at IS NULL OR r.ends_at > now())
$$;

-- THE CAPABILITY MAP. NULL = allowed; otherwise why not.
--
--   ban / suspension   every capability
--   marketplace        post, apply, hire, pay, promote
--   messaging          message
--
-- What is deliberately NOT a capability, and so never blocked: approving a
-- completion, raising or answering a dispute, reading receipts, reporting,
-- and contacting support. Those settle obligations that already exist, and
-- blocking them would strand an INNOCENT counterparty's money or leave a
-- sanctioned person with no route to contest the decision.
CREATE OR REPLACE FUNCTION public.moderation_denial(p_user_id text, p_capability text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_kinds text[];
BEGIN
  IF NOT (p_capability = ANY (public.moderation_capabilities())) THEN
    -- Loud on purpose: a misspelt capability silently answering "allowed"
    -- would be an enforcement gap that looks exactly like enforcement.
    RAISE EXCEPTION 'HELP24_UNKNOWN_CAPABILITY: %', p_capability USING ERRCODE = '22023';
  END IF;

  IF p_user_id IS NULL OR btrim(p_user_id) = '' THEN
    RETURN NULL;
  END IF;

  v_kinds := public.moderation_active_kinds(p_user_id);
  IF cardinality(v_kinds) = 0 THEN
    RETURN NULL;
  END IF;

  IF 'ban' = ANY (v_kinds) THEN RETURN 'banned'; END IF;
  IF 'suspension' = ANY (v_kinds) THEN RETURN 'suspended'; END IF;
  IF 'marketplace' = ANY (v_kinds)
     AND p_capability IN ('post', 'apply', 'hire', 'pay', 'promote') THEN
    RETURN 'marketplace_restricted';
  END IF;
  IF 'messaging' = ANY (v_kinds) AND p_capability = 'message' THEN
    RETURN 'messaging_restricted';
  END IF;
  RETURN NULL;
END;
$$;

-- An account's moderation state as recorded in the ledger's before/after.
CREATE OR REPLACE FUNCTION public.moderation_state_json(p_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH active AS (
    SELECT r.id, r.kind, r.ends_at
      FROM public.account_restrictions r
     WHERE r.user_id = p_user_id
       AND r.lifted_at IS NULL
       AND r.starts_at <= now()
       AND (r.ends_at IS NULL OR r.ends_at > now())
  )
  SELECT jsonb_build_object(
    'status', CASE
      WHEN EXISTS (SELECT 1 FROM active WHERE kind = 'ban') THEN 'banned'
      WHEN EXISTS (SELECT 1 FROM active WHERE kind = 'suspension') THEN 'suspended'
      WHEN EXISTS (SELECT 1 FROM active) THEN 'restricted'
      ELSE 'active' END,
    'restrictions', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'ends_at', ends_at) ORDER BY kind, id)
        FROM active), '[]'::jsonb))
$$;

-- A PERSON'S OWN STATUS, for the app. The one place a user reads moderation
-- data, and it returns only what is theirs to know: the kind of restriction,
-- the reason the admin wrote FOR them, when it ends, and a reference to quote
-- to support. Never the internal note, the admin, or who reported them.
CREATE OR REPLACE FUNCTION public.my_account_status()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid          text := nullif(btrim(coalesce(auth.jwt() ->> 'user_id', '')), '');
  v_restrictions jsonb;
  v_kinds        text[];
  v_denied       jsonb;
  v_warnings     jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'unknown');
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id',        r.id,
           'kind',      r.kind,
           'reason',    r.reason,
           'starts_at', r.starts_at,
           'ends_at',   r.ends_at,
           'reference', upper(left(replace(r.id::text, '-', ''), 8))
         ) ORDER BY r.created_at DESC), '[]'::jsonb),
         coalesce(array_agg(r.kind), '{}'::text[])
    INTO v_restrictions, v_kinds
    FROM public.account_restrictions r
   WHERE r.user_id = v_uid
     AND r.lifted_at IS NULL
     AND r.starts_at <= now()
     AND (r.ends_at IS NULL OR r.ends_at > now());

  SELECT coalesce(jsonb_agg(c ORDER BY c), '[]'::jsonb)
    INTO v_denied
    FROM unnest(public.moderation_capabilities()) AS c
   WHERE public.moderation_denial(v_uid, c) IS NOT NULL;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id',         a.id,
           'reason',     a.reason,
           'created_at', a.created_at,
           'reference',  upper(left(replace(a.id::text, '-', ''), 8))
         ) ORDER BY a.created_at DESC), '[]'::jsonb)
    INTO v_warnings
    FROM public.moderation_actions a
   WHERE a.target_user_id = v_uid
     AND a.action_type = 'warning_issued'
     AND a.created_at > now() - interval '90 days';

  RETURN jsonb_build_object(
    'status', CASE
      WHEN 'ban' = ANY (v_kinds) THEN 'banned'
      WHEN 'suspension' = ANY (v_kinds) THEN 'suspended'
      WHEN cardinality(v_kinds) > 0 THEN 'restricted'
      ELSE 'active' END,
    'restrictions',        v_restrictions,
    'denied_capabilities', v_denied,
    'warnings',            v_warnings,
    'server_time',         now());
END;
$$;

-- For the admin dashboard's user lists: one row per account that has any
-- restriction in force. Absence means "active".
CREATE OR REPLACE VIEW public.moderation_account_state
WITH (security_invoker = true) AS
SELECT
  r.user_id,
  CASE
    WHEN bool_or(r.kind = 'ban') THEN 'banned'
    WHEN bool_or(r.kind = 'suspension') THEN 'suspended'
    ELSE 'restricted'
  END                                                    AS account_status,
  max(r.ends_at) FILTER (WHERE r.kind = 'suspension')    AS suspended_until,
  bool_or(r.kind = 'messaging')                          AS messaging_restricted,
  bool_or(r.kind = 'marketplace')                        AS marketplace_restricted,
  count(*)                                               AS active_restrictions
FROM public.account_restrictions r
WHERE r.lifted_at IS NULL
  AND r.starts_at <= now()
  AND (r.ends_at IS NULL OR r.ends_at > now())
GROUP BY r.user_id;

-- =============================================================================
-- §6  Filing a report — the same rules whichever door it comes through
-- =============================================================================
-- Two doors exist: POST /reports (the backend, service_role) and the direct
-- PostgREST insert the shipped chat sheet performs (authenticated, RLS
-- `user_reports_insert_own` already pins reporter_id to the JWT). Rather than
-- validate twice, the database validates BOTH: the backend is a thin, verified
-- front door and this trigger is the rulebook.

-- Which categories make sense for which target. The app filters its list with
-- the same table (pinned by supabase/tests/trust-safety/report_taxonomy.json).
CREATE OR REPLACE FUNCTION public.moderation_report_categories(p_target_type text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_target_type
    WHEN 'user' THEN ARRAY[
      'scam_or_fraud', 'suspicious_activity', 'harassment', 'threats', 'impersonation',
      'inappropriate_content', 'unsafe_behavior', 'payment_issue', 'illegal_activity',
      'spam', 'other']
    WHEN 'post' THEN ARRAY[
      'scam_or_fraud', 'misleading_listing', 'suspicious_activity', 'illegal_activity',
      'inappropriate_content', 'impersonation', 'payment_issue', 'unsafe_behavior',
      'spam', 'other']
    WHEN 'application' THEN ARRAY[
      'scam_or_fraud', 'suspicious_activity', 'misleading_listing', 'harassment',
      'inappropriate_content', 'impersonation', 'payment_issue', 'unsafe_behavior',
      'spam', 'other']
    WHEN 'message' THEN ARRAY[
      'harassment', 'threats', 'scam_or_fraud', 'payment_issue', 'inappropriate_content',
      'suspicious_activity', 'unsafe_behavior', 'illegal_activity', 'impersonation',
      'spam', 'other']
    ELSE '{}'::text[]
  END
$$;

-- A TRIAGE HINT, NEVER AN ACTION. Where a report lands in the queue — nothing
-- more. The one escalation: three or more DIFFERENT people with open reports
-- against the same account raises it a level, because independent reports are
-- the strongest deterministic signal there is. Repeat reports from ONE person
-- never escalate anything.
CREATE OR REPLACE FUNCTION public.moderation_initial_severity(
  p_reason text, p_reported_user_id text, p_reporter_id text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rank      int;
  v_reporters int;
BEGIN
  v_rank := CASE p_reason
    WHEN 'threats'               THEN 3
    WHEN 'illegal_activity'      THEN 3
    WHEN 'unsafe_behavior'       THEN 3
    WHEN 'scam_or_fraud'         THEN 3
    WHEN 'payment_issue'         THEN 2
    WHEN 'harassment'            THEN 2
    WHEN 'impersonation'         THEN 2
    WHEN 'suspicious_activity'   THEN 2
    WHEN 'inappropriate_content' THEN 2
    ELSE 1
  END;

  SELECT count(DISTINCT reporter_id) INTO v_reporters
    FROM public.user_reports
   WHERE reported_user_id = p_reported_user_id
     AND reporter_id <> p_reporter_id
     AND status IN ('new', 'under_review', 'action_required');

  IF v_reporters + 1 >= 3 THEN
    v_rank := v_rank + 1;
  END IF;

  RETURN (ARRAY['low', 'medium', 'high', 'critical'])[least(v_rank, 4)];
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_user_reports_prepare()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_uuid     CONSTANT text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  v_trusted  boolean := public.moderation_caller_is_trusted();
  v_reported text;
  v_user     public.users%ROWTYPE;
  v_post     public.posts%ROWTYPE;
  v_app      public.applications%ROWTYPE;
  v_msg      public.chat_messages%ROWTYPE;
  v_chat     public.chats%ROWTYPE;
  v_item     jsonb;
  v_count    integer;
BEGIN
  -- ── 1. Server-owned columns ──────────────────────────────────────────────
  -- Whatever the caller sent is discarded. Triage state is written only by the
  -- migration-115 functions; a client inserting `status = 'dismissed'` or its
  -- own severity simply does not get to.
  NEW.status            := 'new';
  NEW.assigned_admin_id := NULL;
  NEW.assigned_at       := NULL;
  NEW.resolved_at       := NULL;
  NEW.resolved_by       := NULL;
  NEW.resolution        := NULL;
  NEW.resolution_reason := NULL;
  NEW.created_at        := now();
  NEW.updated_at        := now();
  NEW.details           := btrim(coalesce(NEW.details, ''));
  NEW.target_snapshot   := '{}'::jsonb;

  IF v_trusted THEN
    NEW.source := coalesce(NEW.source, 'api');
    -- Evidence must be the REPORTER'S OWN uploads. The backend issues upload
    -- paths under reports/<reporter>/, and this refuses anything else — a
    -- reference to somebody else's file is not evidence, it is a leak.
    FOR v_item IN SELECT * FROM jsonb_array_elements(coalesce(NEW.evidence, '[]'::jsonb)) LOOP
      IF jsonb_typeof(v_item) <> 'object'
         OR jsonb_typeof(v_item -> 'path') <> 'string'
         OR (v_item ->> 'path') NOT LIKE ('reports/' || NEW.reporter_id || '/%') THEN
        RAISE EXCEPTION 'HELP24_REPORT_INVALID_EVIDENCE: evidence must be your own upload'
          USING ERRCODE = '22023';
      END IF;
    END LOOP;
  ELSE
    -- The direct-insert door cannot attach evidence at all: nothing on that
    -- path has checked what a path points at.
    NEW.source   := 'app_direct';
    NEW.evidence := '[]'::jsonb;
  END IF;

  -- ── 2. Resolve the target; DERIVE the reported person ───────────────────
  -- The shipped app sends the 084 shape (reported_user_id + optional
  -- message_id) and no target at all. Translate it.
  IF NEW.target_type IS NULL THEN
    NEW.target_type := CASE WHEN NEW.message_id IS NOT NULL THEN 'message' ELSE 'user' END;
    NEW.target_id   := CASE WHEN NEW.message_id IS NOT NULL THEN NEW.message_id::text ELSE NEW.reported_user_id END;
  END IF;
  NEW.target_id := btrim(coalesce(NEW.target_id, ''));
  IF NEW.target_id = '' THEN
    RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: a target is required' USING ERRCODE = '22023';
  END IF;

  IF NEW.target_type IN ('post', 'application', 'message') AND NEW.target_id !~* c_uuid THEN
    RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: malformed id' USING ERRCODE = '22023';
  END IF;

  CASE NEW.target_type
    WHEN 'user' THEN
      SELECT * INTO v_user FROM public.users WHERE id = NEW.target_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: account not found' USING ERRCODE = '22023';
      END IF;
      v_reported := v_user.id;
      NEW.target_snapshot := jsonb_build_object(
        'name',         v_user.name,
        'bio',          left(coalesce(v_user.bio, ''), 2000),
        'profession',   v_user.profession,
        'avatar_url',   coalesce(nullif(v_user.avatar_url, ''), v_user.profile_image),
        'member_since', v_user.created_at);

    WHEN 'post' THEN
      SELECT * INTO v_post FROM public.posts WHERE id = NEW.target_id::uuid;
      IF NOT FOUND OR v_post.author_user_id IS NULL THEN
        RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: listing not found' USING ERRCODE = '22023';
      END IF;
      v_reported  := v_post.author_user_id;
      NEW.post_id := v_post.id;
      NEW.target_snapshot := jsonb_build_object(
        'type',        v_post.type,
        'title',       v_post.title,
        'description', left(coalesce(v_post.description, ''), 4000),
        'category',    v_post.category,
        'location',    v_post.location,
        'price',       v_post.price,
        'status',      v_post.status,
        'created_at',  v_post.created_at);

    WHEN 'application' THEN
      SELECT * INTO v_app FROM public.applications WHERE id = NEW.target_id::uuid;
      IF NOT FOUND OR v_app.applicant_user_id IS NULL THEN
        RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: application not found' USING ERRCODE = '22023';
      END IF;
      SELECT * INTO v_post FROM public.posts WHERE id = v_app.post_id;
      -- Applicants are shown to the listing's owner, and only the owner has a
      -- reason to be reading one.
      IF NOT FOUND OR v_post.author_user_id IS DISTINCT FROM NEW.reporter_id THEN
        RAISE EXCEPTION 'HELP24_REPORT_NOT_PARTICIPANT: only the listing owner can report an application'
          USING ERRCODE = '42501';
      END IF;
      v_reported         := v_app.applicant_user_id;
      NEW.application_id := v_app.id;
      NEW.post_id        := v_app.post_id;
      NEW.target_snapshot := jsonb_build_object(
        'message',        left(coalesce(v_app.message, ''), 4000),
        'proposed_price', v_app.proposed_price,
        'applied_at',     v_app.created_at,
        'post_title',     v_post.title,
        'post_type',      v_post.type);

    WHEN 'message' THEN
      SELECT * INTO v_msg FROM public.chat_messages WHERE id = NEW.target_id::uuid;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: message not found' USING ERRCODE = '22023';
      END IF;
      SELECT * INTO v_chat FROM public.chats WHERE id = v_msg.chat_id;
      -- You can report what was said TO you, in a conversation you are in.
      IF NOT FOUND OR NEW.reporter_id NOT IN (v_chat.user1, v_chat.user2) THEN
        RAISE EXCEPTION 'HELP24_REPORT_NOT_PARTICIPANT: you can only report messages in your own conversations'
          USING ERRCODE = '42501';
      END IF;
      v_reported     := v_msg.sender_id;
      NEW.message_id := v_msg.id;
      NEW.chat_id    := v_msg.chat_id;
      -- The conversation says which listing it is about; the client does not.
      NEW.post_id    := v_chat.post_id;
      NEW.target_snapshot := jsonb_build_object(
        'content',              left(coalesce(v_msg.content, ''), 4000),
        'type',                 v_msg.type,
        'attachment_url',       v_msg.attachment_url,
        'sent_at',              v_msg.created_at,
        'deleted_for_everyone', v_msg.deleted_for_everyone);

    ELSE
      RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: unknown target type %', NEW.target_type
        USING ERRCODE = '22023';
  END CASE;

  -- The shipped client still sends reported_user_id. It must agree with what
  -- the target says; a mismatch is someone aiming a report at a bystander.
  IF NEW.reported_user_id IS NOT NULL AND NEW.reported_user_id <> v_reported THEN
    RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: the reported account does not match the target'
      USING ERRCODE = '22023';
  END IF;
  NEW.reported_user_id := v_reported;

  IF NEW.reporter_id = NEW.reported_user_id THEN
    RAISE EXCEPTION 'HELP24_REPORT_SELF: you cannot report yourself' USING ERRCODE = '23514';
  END IF;

  -- A person reported from a listing: keep that context only when the listing
  -- actually involves one of them (theirs, or the reporter's own that they
  -- answered). Context that points at an unrelated listing is dropped, not
  -- trusted.
  IF NEW.target_type = 'user' AND NEW.post_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.posts p
       WHERE p.id = NEW.post_id
         AND (p.author_user_id IN (NEW.reporter_id, NEW.reported_user_id)
              OR EXISTS (SELECT 1 FROM public.applications a
                          WHERE a.post_id = p.id
                            AND a.applicant_user_id IN (NEW.reporter_id, NEW.reported_user_id)))) THEN
      NEW.post_id := NULL;
    END IF;
  END IF;

  -- A person reported from inside a conversation: both must be in it.
  IF NEW.chat_id IS NOT NULL THEN
    SELECT * INTO v_chat FROM public.chats WHERE id = NEW.chat_id;
    IF NOT FOUND
       OR NEW.reporter_id NOT IN (v_chat.user1, v_chat.user2)
       OR NEW.reported_user_id NOT IN (v_chat.user1, v_chat.user2) THEN
      RAISE EXCEPTION 'HELP24_REPORT_NOT_PARTICIPANT: that conversation is not between you and this account'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- ── 3. The category must make sense for the target ─────────────────────
  IF NOT (NEW.reason = ANY (public.moderation_report_categories(NEW.target_type))) THEN
    RAISE EXCEPTION 'HELP24_REPORT_INVALID_CATEGORY: % does not apply to a %', NEW.reason, NEW.target_type
      USING ERRCODE = '22023';
  END IF;

  -- ── 4. Abuse controls ──────────────────────────────────────────────────
  -- Same person, same thing, within a day: already heard. (Still-open
  -- duplicates older than a day are caught by user_reports_one_open_per_target.)
  IF EXISTS (
    SELECT 1 FROM public.user_reports r
     WHERE r.reporter_id = NEW.reporter_id
       AND r.target_type = NEW.target_type
       AND r.target_id   = NEW.target_id
       AND r.created_at  > now() - interval '24 hours') THEN
    RAISE EXCEPTION 'HELP24_REPORT_DUPLICATE: you have already reported this' USING ERRCODE = 'P0001';
  END IF;

  -- Volume. Ten a day is far past anyone reporting honestly and well short of
  -- someone trying to bury the queue; five against one account stops a feud
  -- from being fought through the report button.
  SELECT count(*) INTO v_count
    FROM public.user_reports r
   WHERE r.reporter_id = NEW.reporter_id
     AND r.created_at > now() - interval '24 hours';
  IF v_count >= 10 THEN
    RAISE EXCEPTION 'HELP24_REPORT_LIMIT: too many reports today' USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*) INTO v_count
    FROM public.user_reports r
   WHERE r.reporter_id = NEW.reporter_id
     AND r.reported_user_id = NEW.reported_user_id
     AND r.created_at > now() - interval '24 hours';
  IF v_count >= 5 THEN
    RAISE EXCEPTION 'HELP24_REPORT_LIMIT: too many reports about this account today' USING ERRCODE = 'P0001';
  END IF;

  -- ── 5. Where it lands in the queue ──────────────────────────────────────
  NEW.severity := public.moderation_initial_severity(NEW.reason, NEW.reported_user_id, NEW.reporter_id);

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_reports_prepare ON public.user_reports;
CREATE TRIGGER trg_user_reports_prepare
  BEFORE INSERT ON public.user_reports
  FOR EACH ROW EXECUTE FUNCTION public.fn_user_reports_prepare();

-- The allegation is evidence: frozen once filed. Only triage fields move, and
-- only inside the migration-115 functions. Nothing is ever deleted.
CREATE OR REPLACE FUNCTION public.fn_user_reports_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'HELP24_MODERATION_HISTORY_IMMUTABLE: reports are evidence and are never deleted'
      USING ERRCODE = '42501';
  END IF;

  IF (NEW.id, NEW.reporter_id, NEW.reported_user_id, NEW.target_type, NEW.target_id, NEW.reason,
      NEW.details, NEW.evidence, NEW.target_snapshot, NEW.chat_id, NEW.post_id, NEW.message_id,
      NEW.application_id, NEW.source, NEW.created_at)
     IS DISTINCT FROM
     (OLD.id, OLD.reporter_id, OLD.reported_user_id, OLD.target_type, OLD.target_id, OLD.reason,
      OLD.details, OLD.evidence, OLD.target_snapshot, OLD.chat_id, OLD.post_id, OLD.message_id,
      OLD.application_id, OLD.source, OLD.created_at) THEN
    RAISE EXCEPTION 'HELP24_REPORT_IMMUTABLE: a report cannot be edited after it is filed'
      USING ERRCODE = '42501';
  END IF;

  IF coalesce(current_setting('help24.moderation_write', true), '') <> 'on' THEN
    RAISE EXCEPTION 'HELP24_MODERATION_WRITE_REQUIRED: report triage changes only through the moderation functions'
      USING ERRCODE = '42501';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_reports_guard ON public.user_reports;
CREATE TRIGGER trg_user_reports_guard
  BEFORE UPDATE OR DELETE ON public.user_reports
  FOR EACH ROW EXECUTE FUNCTION public.fn_user_reports_guard();

DROP TRIGGER IF EXISTS trg_user_reports_no_truncate ON public.user_reports;
CREATE TRIGGER trg_user_reports_no_truncate
  BEFORE TRUNCATE ON public.user_reports
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_moderation_history_immutable();

-- =============================================================================
-- §7  Carry any legacy ban across (0 on 2026-09-27)
-- =============================================================================
-- A user banned with the old toggle stays banned, now with a row that says so.
-- The system is named as the actor because nobody recorded who the admin was.
DO $$
DECLARE
  r record;
  v_restriction uuid;
BEGIN
  FOR r IN
    SELECT u.id FROM public.users u
     WHERE u.is_banned
       AND NOT EXISTS (
         SELECT 1 FROM public.account_restrictions ar
          WHERE ar.user_id = u.id AND ar.kind = 'ban' AND ar.lifted_at IS NULL)
  LOOP
    INSERT INTO public.account_restrictions (user_id, kind, reason, created_by_system)
    VALUES (r.id, 'ban',
            'Your account was restricted by Help24 before this record existed. Contact support to review it.',
            true)
    RETURNING id INTO v_restriction;

    INSERT INTO public.moderation_actions
      (target_user_id, action_type, actor_type, restriction_id, reason, new_state, metadata)
    VALUES
      (r.id, 'legacy_ban_imported', 'system', v_restriction,
       'Carried over from users.is_banned, which recorded no reason or admin.',
       public.moderation_state_json(r.id),
       jsonb_build_object('migration', '114'));
  END LOOP;
END $$;

-- =============================================================================
-- §8  Access
-- =============================================================================
-- Default privileges on this project grant every new table ALL to
-- service_role, and every new function EXECUTE to PUBLIC. Both are wrong here
-- and are reversed explicitly: the moderation tables are read-only to the
-- backend (writes go through the 115 functions), and no function in this file
-- is callable from the app except my_account_status().

ALTER TABLE public.account_restrictions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.moderation_actions   ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.account_restrictions, public.moderation_actions FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.account_restrictions, public.moderation_actions TO service_role;

-- user_reports: the reporter may INSERT (084's policy still pins reporter_id to
-- the JWT); nobody may read, change or remove a report except through the
-- backend and the 115 functions.
REVOKE ALL ON public.user_reports FROM PUBLIC, anon, authenticated, service_role;
GRANT INSERT ON public.user_reports TO authenticated;
GRANT SELECT, INSERT ON public.user_reports TO service_role;

REVOKE ALL ON public.moderation_audit_integrity, public.moderation_account_state FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.moderation_audit_integrity, public.moderation_account_state TO service_role;

REVOKE ALL ON FUNCTION public.moderation_caller_is_trusted()                       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_action_hash_body(public.moderation_actions) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_moderation_actions_seal()                         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_moderation_history_immutable()                    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_account_restrictions_guard()                      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_users_is_banned_guard()                           FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_capabilities()                            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_active_kinds(text)                        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_denial(text, text)                        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_state_json(text)                          FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.my_account_status()                                  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_report_categories(text)                   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_initial_severity(text, text, text)        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_user_reports_prepare()                            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_user_reports_guard()                              FROM PUBLIC, anon, authenticated;

-- The integrity view is security_invoker, so whoever reads it needs the hash
-- function too. Pure — it reads no table.
GRANT EXECUTE ON FUNCTION public.moderation_action_hash_body(public.moderation_actions) TO service_role;
GRANT EXECUTE ON FUNCTION public.moderation_capabilities()          TO service_role;
GRANT EXECUTE ON FUNCTION public.moderation_denial(text, text)      TO service_role;
GRANT EXECUTE ON FUNCTION public.moderation_state_json(text)        TO service_role;
GRANT EXECUTE ON FUNCTION public.moderation_report_categories(text) TO service_role;
-- The ONE moderation function the app may call. It reads the caller's own
-- JWT and cannot be pointed at anyone else.
GRANT EXECUTE ON FUNCTION public.my_account_status() TO authenticated;

COMMIT;
