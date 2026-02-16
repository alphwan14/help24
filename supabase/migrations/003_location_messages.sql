-- =============================================================================
-- RUN THIS IN SUPABASE SQL EDITOR
-- =============================================================================
-- Location sharing: add type, latitude, longitude, live_until to messages
-- type: 'text' | 'image' | 'location' | 'live_location'
-- =============================================================================

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS type text NOT NULL DEFAULT 'text',
  ADD COLUMN IF NOT EXISTS latitude double precision,
  ADD COLUMN IF NOT EXISTS longitude double precision,
  ADD COLUMN IF NOT EXISTS live_until timestamptz;

COMMENT ON COLUMN public.messages.type IS 'text, image, location, or live_location';
COMMENT ON COLUMN public.messages.latitude IS 'Latitude for location/live_location messages';
COMMENT ON COLUMN public.messages.longitude IS 'Longitude for location/live_location messages';
COMMENT ON COLUMN public.messages.live_until IS 'When live sharing ends; null for static location';

-- Allow UPDATE so live location can be updated in real time
DROP POLICY IF EXISTS "Messages update" ON public.messages;
CREATE POLICY "Messages update"
  ON public.messages FOR UPDATE
  TO anon, authenticated
  USING (true)
  WITH CHECK (true);
