-- ============================================
-- Help24 Supabase STORAGE Setup (FIXED RLS)
-- ============================================
-- 
-- This fixes the error:
-- "new row violates row-level security policy"
-- 
-- Run this SQL in Supabase SQL Editor
-- ============================================

-- ============================================
-- STEP 1: Create bucket if it doesn't exist
-- ============================================
-- Note: Buckets are usually created via Dashboard, but this ensures it exists
INSERT INTO storage.buckets (id, name, public)
VALUES ('post-images', 'post-images', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- ============================================
-- STEP 2: Drop ALL existing storage policies
-- ============================================
DROP POLICY IF EXISTS "Public Access" ON storage.objects;
DROP POLICY IF EXISTS "Public Read" ON storage.objects;
DROP POLICY IF EXISTS "Public Upload" ON storage.objects;
DROP POLICY IF EXISTS "Allow public read" ON storage.objects;
DROP POLICY IF EXISTS "Allow public upload" ON storage.objects;
DROP POLICY IF EXISTS "Public read access" ON storage.objects;
DROP POLICY IF EXISTS "Allow uploads" ON storage.objects;
DROP POLICY IF EXISTS "allow_public_read_post_images" ON storage.objects;
DROP POLICY IF EXISTS "allow_public_upload_post_images" ON storage.objects;
DROP POLICY IF EXISTS "allow_public_delete_post_images" ON storage.objects;
DROP POLICY IF EXISTS "post_images_public_select" ON storage.objects;
DROP POLICY IF EXISTS "post_images_public_insert" ON storage.objects;
DROP POLICY IF EXISTS "post_images_public_delete" ON storage.objects;
DROP POLICY IF EXISTS "post_images_public_update" ON storage.objects;
DROP POLICY IF EXISTS "Give anon users access to images" ON storage.objects;
DROP POLICY IF EXISTS "Give users access to own folder" ON storage.objects;
DROP POLICY IF EXISTS "Anyone can upload" ON storage.objects;
DROP POLICY IF EXISTS "Anyone can view" ON storage.objects;

-- ============================================
-- STEP 3: Create PERMISSIVE policies for post-images bucket
-- ============================================

-- Allow ANYONE to SELECT (view/download) images
CREATE POLICY "Anyone can view post-images"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'post-images');

-- Allow ANYONE to INSERT (upload) images
-- This is the key policy that was missing!
CREATE POLICY "Anyone can upload to post-images"
ON storage.objects FOR INSERT
TO public
WITH CHECK (bucket_id = 'post-images');

-- Allow ANYONE to UPDATE images
CREATE POLICY "Anyone can update post-images"
ON storage.objects FOR UPDATE
TO public
USING (bucket_id = 'post-images');

-- Allow ANYONE to DELETE images
CREATE POLICY "Anyone can delete from post-images"
ON storage.objects FOR DELETE
TO public
USING (bucket_id = 'post-images');

-- ============================================
-- STEP 4: Verify the setup
-- ============================================

-- Check bucket exists and is public:
SELECT id, name, public, created_at 
FROM storage.buckets 
WHERE id = 'post-images';

-- Check RLS policies on storage.objects:
SELECT policyname, permissive, roles, cmd
FROM pg_policies 
WHERE tablename = 'objects' AND schemaname = 'storage'
ORDER BY policyname;

-- ============================================
-- ALTERNATIVE: If policies still block, disable RLS entirely
-- ============================================
-- DANGER: Only use this for development!
-- Uncomment the line below if nothing else works:
-- ALTER TABLE storage.objects DISABLE ROW LEVEL SECURITY;

-- ============================================
-- DONE! Test upload should now work.
-- ============================================
