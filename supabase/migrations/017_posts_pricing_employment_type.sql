-- =============================================================================
-- Posts: add pricing_type and employment_type for offer/request/job.
-- post_type remains the existing "type" column (request, offer, job).
-- =============================================================================

-- pricing_type: how price is quoted (task, hour, day, week, month)
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS pricing_type text NOT NULL DEFAULT 'task';
ALTER TABLE public.posts DROP CONSTRAINT IF EXISTS posts_pricing_type_check;
ALTER TABLE public.posts ADD CONSTRAINT posts_pricing_type_check
  CHECK (pricing_type IN ('task', 'hour', 'day', 'week', 'month'));

-- employment_type: only for type = 'job' (full_time, part_time, contract, temporary)
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS employment_type text;
ALTER TABLE public.posts DROP CONSTRAINT IF EXISTS posts_employment_type_check;
ALTER TABLE public.posts ADD CONSTRAINT posts_employment_type_check
  CHECK (employment_type IS NULL OR employment_type IN ('full_time', 'part_time', 'contract', 'temporary'));

-- Enforce employment_type required when type = 'job'
CREATE OR REPLACE FUNCTION public.posts_validate_job_employment_type()
RETURNS trigger AS $$
BEGIN
  IF NEW.type = 'job' AND (NEW.employment_type IS NULL OR NEW.employment_type = '') THEN
    RAISE EXCEPTION 'employment_type is required when type is job';
  END IF;
  IF NEW.type != 'job' THEN
    NEW.employment_type := NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS posts_validate_job_employment_trigger ON public.posts;
CREATE TRIGGER posts_validate_job_employment_trigger
  BEFORE INSERT OR UPDATE ON public.posts
  FOR EACH ROW EXECUTE PROCEDURE public.posts_validate_job_employment_type();

COMMENT ON COLUMN public.posts.pricing_type IS 'How price is quoted: task, hour, day, week, month';
COMMENT ON COLUMN public.posts.employment_type IS 'For type=job only: full_time, part_time, contract, temporary';
