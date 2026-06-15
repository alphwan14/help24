-- =============================================================================
-- Migration 047: dispute_evidence — files/text submitted to an arbitration case
-- =============================================================================
-- Evidence can come from either party (client/provider), an admin, or the system
-- (e.g. an auto-attached chat transcript). Files are stored in Supabase Storage;
-- this row holds the public/signed URL (file_url) or inline text (content).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.dispute_evidence (
  id            UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  dispute_id    UUID        NOT NULL REFERENCES public.disputes(id) ON DELETE CASCADE,

  -- Who uploaded it. For users this is users.id (TEXT/Firebase UID); for admins
  -- it is admin_users.id (UUID) serialised as text. uploader_type disambiguates.
  uploaded_by   TEXT        NOT NULL,
  uploader_type TEXT        NOT NULL CHECK (uploader_type IN ('client','provider','admin','system')),

  type          TEXT        NOT NULL CHECK (type IN ('image','video','text','system_chat')),
  file_url      TEXT,       -- for image/video (Supabase Storage URL)
  content       TEXT,       -- for text/system_chat (inline)

  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- An evidence row must carry SOMETHING: a file URL or inline content.
  CONSTRAINT dispute_evidence_payload_present
    CHECK (file_url IS NOT NULL OR content IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_dispute_evidence_dispute ON public.dispute_evidence (dispute_id, created_at);

ALTER TABLE public.dispute_evidence ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'dispute_evidence_service_role' AND tablename = 'dispute_evidence'
  ) THEN
    CREATE POLICY dispute_evidence_service_role ON public.dispute_evidence
      USING (true) WITH CHECK (true);
  END IF;
END $$;

GRANT ALL ON public.dispute_evidence TO service_role;
