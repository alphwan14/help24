-- Add urgent-post and geo alignment fields.
ALTER TABLE IF EXISTS public.posts
  ADD COLUMN IF NOT EXISTS is_urgent BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS latitude DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS urgent_expires_at TIMESTAMP;

-- Keep existing rows safe and deterministic.
UPDATE public.posts
SET is_urgent = FALSE
WHERE is_urgent IS NULL;

-- Optional backfill: if a row is already urgent and has no expiry, expire 1 hour after creation.
UPDATE public.posts
SET urgent_expires_at = COALESCE(urgent_expires_at, created_at + INTERVAL '1 hour')
WHERE is_urgent = TRUE;

-- Indexes for urgent filtering and geo sorting.
CREATE INDEX IF NOT EXISTS idx_posts_is_urgent
  ON public.posts (is_urgent);

CREATE INDEX IF NOT EXISTS idx_posts_lat_lng
  ON public.posts (latitude, longitude);

CREATE INDEX IF NOT EXISTS idx_posts_urgent_expires_at
  ON public.posts (urgent_expires_at);

