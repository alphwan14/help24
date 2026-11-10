-- =============================================================================
-- Migration 143: photos in Message Help24
-- =============================================================================
-- ADDITIVE, plus one widened CHECK. No rows change.
--
-- A member can now attach photos to a message in the app (a screenshot of an
-- error, a receipt, the job). They live in a PRIVATE bucket and are only ever
-- reached through short-lived signed links the backend makes for the member's
-- own thread and for staff in the Inbox. Same pattern as dispute evidence (057)
-- and chat attachments (118).
--
--   storage bucket support-attachments  private; images only (JPG, PNG, WebP);
--                                       10 MB each, enforced by Storage itself.
--                                       No storage.objects policy on purpose:
--                                       anon and authenticated get nothing.
--   support_messages.attachments        [{ "path": "members/<uid>/<uuid>.jpg",
--                                          "mime": "image/jpeg" }], at most 5.
--   support_messages_body_check         a message may be photos only: the text
--                                       may now be empty when it has a photo.
--
-- Rollback (only while no message is photos-only):
--   ALTER TABLE public.support_messages DROP CONSTRAINT support_messages_body_check;
--   ALTER TABLE public.support_messages ADD CONSTRAINT support_messages_body_check
--     CHECK (char_length(body) BETWEEN 1 AND 20000);
--   ALTER TABLE public.support_messages DROP COLUMN attachments;
--   (the bucket and its objects: delete from Storage in the dashboard)
-- =============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'support-attachments',
  'support-attachments',
  false,
  10485760,  -- 10 MB per file
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
  public             = false,
  file_size_limit    = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

ALTER TABLE public.support_messages
  ADD COLUMN IF NOT EXISTS attachments jsonb NOT NULL DEFAULT '[]'::jsonb
    CONSTRAINT support_messages_attachments_check
    CHECK (jsonb_typeof(attachments) = 'array' AND jsonb_array_length(attachments) <= 5);

ALTER TABLE public.support_messages DROP CONSTRAINT IF EXISTS support_messages_body_check;
ALTER TABLE public.support_messages ADD CONSTRAINT support_messages_body_check
  CHECK (char_length(body) <= 20000 AND (char_length(body) >= 1 OR jsonb_array_length(attachments) >= 1));

COMMENT ON COLUMN public.support_messages.attachments IS
  'Photos on an app message: [{path, mime}] in the private support-attachments bucket (migration 143).';
