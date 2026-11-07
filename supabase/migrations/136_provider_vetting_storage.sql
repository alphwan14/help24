-- =============================================================================
-- Migration 136: private storage for provider verification documents
-- =============================================================================
-- ADDITIVE. One private bucket and one INSERT policy. Apply after 135.
--
-- The app uploads ID photos, selfies and the DCI certificate / eCitizen receipt
-- (photo or PDF, as eCitizen issues them) to '<user_id>/<random>.<ext>' and
-- then calls submit_provider_verification(), which checks the objects exist.
--
-- Nobody but the backend reads these files: there is deliberately no SELECT,
-- UPDATE or DELETE policy, so the uploader cannot read them back either (a
-- stolen session cannot download someone's ID). Admins view them through
-- short-lived signed URLs minted by the backend; the backend deletes them 30
-- days after the decision.
--
-- Rollback (after the app no longer uploads here; empty the bucket first in
-- the dashboard or with the storage API):
--   DROP POLICY IF EXISTS provider_verifications_insert_own ON storage.objects;
--   DELETE FROM storage.buckets WHERE id = 'provider-verifications';
-- =============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'provider-verifications',
  'provider-verifications',
  false,
  8388608,  -- 8 MB: a phone photo of an ID, or an eCitizen PDF
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
ON CONFLICT (id) DO UPDATE
  SET public             = false,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS provider_verifications_insert_own ON storage.objects;
CREATE POLICY provider_verifications_insert_own ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'provider-verifications'
    AND (storage.foldername(name))[1] = (SELECT auth.jwt() ->> 'user_id')
  );
