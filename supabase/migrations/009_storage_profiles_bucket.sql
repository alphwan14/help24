-- =============================================================================
-- RUN IN SUPABASE SQL EDITOR (after 008)
-- =============================================================================
-- Create "profiles" storage bucket and allow uploads so profile image upload
-- does not return 403. Public bucket so profile images are viewable by URL.
-- =============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'profiles',
  'profiles',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/gif', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Allow upload (insert) and read (select) for anon + authenticated (app uses anon key)
DROP POLICY IF EXISTS "profiles_upload" ON storage.objects;
CREATE POLICY "profiles_upload"
  ON storage.objects FOR INSERT
  TO anon, authenticated
  WITH CHECK (bucket_id = 'profiles');

DROP POLICY IF EXISTS "profiles_read" ON storage.objects;
CREATE POLICY "profiles_read"
  ON storage.objects FOR SELECT
  TO anon, authenticated
  USING (bucket_id = 'profiles');

DROP POLICY IF EXISTS "profiles_update" ON storage.objects;
CREATE POLICY "profiles_update"
  ON storage.objects FOR UPDATE
  TO anon, authenticated
  USING (bucket_id = 'profiles')
  WITH CHECK (bucket_id = 'profiles');
