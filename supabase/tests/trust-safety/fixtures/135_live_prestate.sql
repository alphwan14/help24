-- What migration 135 builds on, as it is live but missing from the replica
-- (which predates it): the category rows (migration 070's seed — names are
-- byte-identical to production), the public_profiles view (migration 123) and
-- a minimal stand-in for Supabase Storage, enough to exercise migration 136's
-- policy and submit_provider_verification's "the files exist" check.

INSERT INTO public.categories (id, name, icon, sort) VALUES
  ('plumbing', 'Plumbing', 'plumbing', 10),
  ('house-cleaning', 'House Cleaning', 'cleaning_services', 70),
  ('security-guard', 'Security Guard', 'security', 100),
  ('driver', 'Driver', 'directions_car', 110),
  ('tutoring', 'Tutoring', 'school', 250),
  ('babysitting', 'Babysitting', 'child_care', 260),
  ('caregiving', 'Caregiving', 'favorite', 270),
  ('other', 'Other', 'more_horiz', 999)
ON CONFLICT (id) DO NOTHING;

create or replace view public.public_profiles as
select
  id,
  name,
  coalesce(nullif(avatar_url, ''), nullif(profile_image, '')) as avatar_url,
  phone_number is not null and phone_number <> '' as has_phone,
  nullif(profile_image, '') as profile_image,
  profession,
  bio,
  created_at,
  last_seen,
  is_online
from public.users;
grant select on public.public_profiles to anon, authenticated;

-- ── Storage stand-in ─────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS storage;
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS storage.buckets (
  id                 text PRIMARY KEY,
  name               text NOT NULL,
  public             boolean DEFAULT false,
  file_size_limit    bigint,
  allowed_mime_types text[]
);

CREATE TABLE IF NOT EXISTS storage.objects (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id text REFERENCES storage.buckets(id),
  name      text NOT NULL,
  owner_id  text,
  UNIQUE (bucket_id, name)
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO authenticated, service_role;
GRANT SELECT ON storage.buckets TO anon, authenticated, service_role;

-- Supabase's own definition: every path segment but the file name.
CREATE OR REPLACE FUNCTION storage.foldername(name text)
RETURNS text[] LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE _parts text[];
BEGIN
  SELECT string_to_array(name, '/') INTO _parts;
  RETURN _parts[1:array_length(_parts, 1) - 1];
END
$f$;
GRANT EXECUTE ON FUNCTION storage.foldername(text) TO anon, authenticated, service_role;
