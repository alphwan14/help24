-- =============================================================================
-- Migration 057: Dispute Communication & Evidence System (Phase 3.3 — Stage 1)
-- =============================================================================
-- Turns the existing arbitration case (disputes / dispute_messages /
-- dispute_evidence — migrations 032/046/047/048) into a full participant-facing
-- communication channel WITHOUT breaking the admin Arbitration Centre.
--
-- This migration is ADDITIVE and BACKWARD COMPATIBLE:
--   • only ADD COLUMN / expand CHECK constraints — no drops of data or columns
--   • all new columns are nullable or carry a safe default
--   • legacy statuses/types are retained in every CHECK
--
-- What it adds:
--   1. Three transient review sub-states on disputes (awaiting_* evidence/review)
--   2. dispute_messages: kind (timeline classifier), internal (admin-only),
--      hidden_at/hidden_by (soft-hide — audit never deletes)
--   3. dispute_evidence: reviewed_at/reviewed_by (admin review tracking),
--      file metadata (name/mime/size), 'document' type, hidden_at/hidden_by
--   4. A PRIVATE `dispute-evidence` storage bucket (no public policy; all access
--      is service-role-mediated via backend-issued signed URLs)
-- =============================================================================


-- ── 1. disputes: add the three transient review sub-states ───────────────────
-- open → reviewing → awaiting_{client,provider}_evidence → awaiting_admin_review
--      → reviewing → resolved | escalated.  Terminal outcome stays derived from
-- dispute_decisions.decision_type (no status drift).
DO $$
DECLARE ck_name TEXT;
BEGIN
  SELECT tc.constraint_name INTO ck_name
    FROM information_schema.table_constraints tc
   WHERE tc.table_schema='public' AND tc.table_name='disputes'
     AND tc.constraint_type='CHECK' AND tc.constraint_name ILIKE '%status%'
   LIMIT 1;
  IF ck_name IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.disputes DROP CONSTRAINT ' || quote_ident(ck_name);
  END IF;
END $$;

ALTER TABLE public.disputes
  ADD CONSTRAINT disputes_status_check
  CHECK (status IN (
    -- production lifecycle
    'open', 'reviewing', 'resolved', 'escalated', 'merged',
    -- Phase 3.3 transient evidence sub-states (non-terminal)
    'awaiting_client_evidence', 'awaiting_provider_evidence', 'awaiting_admin_review',
    -- legacy (migration 032 / legacy resolver) — kept so old rows stay valid
    'under_review', 'resolved_release', 'resolved_refund', 'resolved_partial'
  ));


-- ── 2. dispute_messages: timeline classifier + internal notes + soft-hide ────
ALTER TABLE public.dispute_messages
  ADD COLUMN IF NOT EXISTS kind        TEXT        NOT NULL DEFAULT 'text',
  ADD COLUMN IF NOT EXISTS internal    BOOLEAN     NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS hidden_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS hidden_by   TEXT;

-- kind classifies the entry for deterministic timeline rendering on mobile.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema='public' AND table_name='dispute_messages'
      AND constraint_name='dispute_messages_kind_check'
  ) THEN
    ALTER TABLE public.dispute_messages
      ADD CONSTRAINT dispute_messages_kind_check
      CHECK (kind IN ('text','evidence_request','evidence_submitted','system','resolution'));
  END IF;
END $$;

-- Backfill: existing system-authored rows are 'system', everything else 'text'.
UPDATE public.dispute_messages SET kind = 'system'
  WHERE sender_type = 'system' AND kind = 'text';

COMMENT ON COLUMN public.dispute_messages.internal IS
  'Admin-only note. Participant reads (DisputesPublicController) filter internal=true out.';
COMMENT ON COLUMN public.dispute_messages.hidden_at IS
  'Soft-hide marker. Rows are NEVER deleted — hidden entries stay auditable.';


-- ── 3. dispute_evidence: review tracking + file metadata + soft-hide ─────────
ALTER TABLE public.dispute_evidence
  ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS reviewed_by TEXT,            -- admin_users.id (UUID as text)
  ADD COLUMN IF NOT EXISTS file_name   TEXT,
  ADD COLUMN IF NOT EXISTS mime_type   TEXT,
  ADD COLUMN IF NOT EXISTS size_bytes  BIGINT,
  ADD COLUMN IF NOT EXISTS hidden_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS hidden_by   TEXT;

-- Expand the type CHECK to add 'document' (PDF). Retain legacy values.
-- NOTE: file_url now stores the STORAGE OBJECT PATH for new uploads (the backend
-- signs it on read). Legacy rows holding a full URL still render (pass-through).
DO $$
DECLARE ck_name TEXT;
BEGIN
  SELECT tc.constraint_name INTO ck_name
    FROM information_schema.table_constraints tc
   WHERE tc.table_schema='public' AND tc.table_name='dispute_evidence'
     AND tc.constraint_type='CHECK' AND tc.constraint_name ILIKE '%type%'
     AND tc.constraint_name NOT ILIKE '%payload%'
   LIMIT 1;
  IF ck_name IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.dispute_evidence DROP CONSTRAINT ' || quote_ident(ck_name);
  END IF;
END $$;

ALTER TABLE public.dispute_evidence
  ADD CONSTRAINT dispute_evidence_type_check
  CHECK (type IN ('image','document','text','system_chat','video'));

COMMENT ON COLUMN public.dispute_evidence.file_url IS
  'For file evidence: the PRIVATE bucket object path (e.g. disputes/<id>/<uuid>.jpg). '
  'The backend mints a short-TTL signed URL on every read. Legacy full-URL rows pass through.';
COMMENT ON COLUMN public.dispute_evidence.reviewed_at IS
  'Set when an admin marks this evidence reviewed (PATCH /disputes/:id/evidence/:eid/reviewed).';


-- ── 4. Private storage bucket for dispute evidence ───────────────────────────
-- public=false → objects are NOT served by URL. The ONLY access path is a
-- backend-issued signed upload/download URL (service_role). No storage.objects
-- policy is created on purpose: anon/authenticated have ZERO access; service_role
-- bypasses RLS. file_size_limit + allowed_mime_types are enforced by Storage
-- itself, independent of any client-supplied claim.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'dispute-evidence',
  'dispute-evidence',
  false,
  10485760,  -- 10 MB per file
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
ON CONFLICT (id) DO UPDATE SET
  public            = EXCLUDED.public,
  file_size_limit   = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Defensive: ensure no public-read policy leaked onto this bucket from a prior
-- migration. (profiles_read in 009 is scoped to bucket_id='profiles'.)
DROP POLICY IF EXISTS "dispute_evidence_read"   ON storage.objects;
DROP POLICY IF EXISTS "dispute_evidence_upload" ON storage.objects;
