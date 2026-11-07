-- =============================================================================
-- Migration 135: provider vetting — ID check and Care check
-- =============================================================================
-- ADDITIVE. One new table, two nullable columns on posts, one nullable column
-- on categories, two triggers, an extended public_profiles view (columns
-- appended, none changed) and the functions below. Design and decisions:
-- docs/provider-vetting.md.
--
-- WHAT IT ENFORCES
--   Vetting is keyed to the CATEGORY OF WORK on the listing (posts.category),
--   not the profession picked at sign-up. categories.vetting_tier says which
--   check a category needs:
--     'id'   — ID check: national ID / passport / alien ID + a selfie holding it.
--              Tutoring, Driver, Security Guard, House Cleaning.
--     'care' — Care check: the ID check plus a DCI Certificate of Good Conduct.
--              Babysitting, Caregiving.
--
--   Offering the work (type = 'offer'):
--     * needs the category's check;
--     * Care check only: an approved eCitizen application RECEIPT is accepted for
--       30 days while the certificate is pending. The offer is listed with the
--       label 'certificate_pending' and is hidden when the 30 days run out
--       without an approved certificate.
--   Applying for the work (requests and jobs in that category):
--     * needs the FULL check. A pending certificate is not enough.
--   Being hired: the backend's select-provider refuses a provider who does not
--   hold the full check (provider_meets_vetting, below).
--   Messaging is never restricted by vetting.
--
--   Posts and applications are written straight to the database by the app, so
--   the rules live here, in triggers. The backend and migrations (service role
--   / owner) are trusted, exactly as moderation (migration 116).
--
-- LISTINGS POSTED BEFORE THIS MIGRATION
--   Open offers in a vetted category whose author is not verified keep showing
--   for 14 days with the label 'not_verified' (vetting_hide_at = apply time +
--   14 days). After that the backend sweep (vetting_sweep) hides them —
--   archived_by = 'vetting' — until the author completes the check; approval
--   reopens them automatically.
--
-- PRIVACY (Data Protection Act 2019)
--   Document images live in the private 'provider-verifications' bucket
--   (migration 136). provider_verifications is unreadable to clients; the app
--   sees only its own status through my_verification_status(). The public sees
--   only the outcome (public_profiles.id_verified / care_status). The backend
--   deletes the images 30 days after the decision (files_deleted_at).
--
-- DEPLOY ORDER: this, then 136 (storage), then the backend (review endpoints
-- and sweep), then the admin dashboard, then the app.
--
-- Rollback (after rolling back backend, dashboard and app):
--   DROP TRIGGER IF EXISTS trg_posts_vetting_guard ON public.posts;
--   DROP TRIGGER IF EXISTS trg_applications_vetting_guard ON public.applications;
--   UPDATE public.posts SET archived_at = NULL, archived_by = NULL
--    WHERE archived_by = 'vetting';
--   -- public_profiles: re-run the CREATE OR REPLACE from migration 123 after
--   -- DROP VIEW public.public_profiles (appended columns cannot be removed by
--   -- CREATE OR REPLACE), then re-grant SELECT to anon, authenticated.
--   DROP FUNCTION IF EXISTS public.vetting_sweep(), public.vetting_refresh_author_posts(text),
--     public.review_provider_verification(uuid, text, text, text),
--     public.submit_provider_verification(text, text, text[]),
--     public.my_verification_status(), public.provider_meets_vetting(text, text, boolean),
--     public.vetting_post_flags(text, text, text), public.provider_vetting_state(text),
--     public.vetting_tier_for_category(text), public.fn_posts_vetting_guard(),
--     public.fn_applications_vetting_guard();
--   DROP TABLE IF EXISTS public.provider_verifications;
--   ALTER TABLE public.posts DROP COLUMN IF EXISTS vetting_label,
--                            DROP COLUMN IF EXISTS vetting_hide_at;
--   ALTER TABLE public.categories DROP COLUMN IF EXISTS vetting_tier;
--   UPDATE public.users SET is_verified = false WHERE is_verified;
-- =============================================================================

-- =============================================================================
-- §1  Which categories need which check
-- =============================================================================

ALTER TABLE public.categories
  ADD COLUMN IF NOT EXISTS vetting_tier TEXT;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'categories_vetting_tier_check') THEN
    ALTER TABLE public.categories
      ADD CONSTRAINT categories_vetting_tier_check
      CHECK (vetting_tier IS NULL OR vetting_tier IN ('id', 'care'));
  END IF;
END $$;

COMMENT ON COLUMN public.categories.vetting_tier IS
  'Check a provider needs to offer or apply for work in this category: NULL (none), ''id'' (ID check) or ''care'' (ID check + DCI Certificate of Good Conduct). Migration 135.';

-- Only fills categories that have no tier yet, so a re-run never undoes a later
-- decision to move a category.
UPDATE public.categories SET vetting_tier = 'care'
 WHERE id IN ('babysitting', 'caregiving') AND vetting_tier IS NULL;
UPDATE public.categories SET vetting_tier = 'id'
 WHERE id IN ('tutoring', 'driver', 'security-guard', 'house-cleaning') AND vetting_tier IS NULL;

-- posts.category holds the category NAME (byte-identical to categories.name,
-- migration 070); a slug is accepted too.
CREATE OR REPLACE FUNCTION public.vetting_tier_for_category(p_category text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT c.vetting_tier
    FROM public.categories c
   WHERE c.name = p_category OR c.id = p_category
   ORDER BY (c.name = p_category) DESC
   LIMIT 1
$$;

-- =============================================================================
-- §2  Submissions
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.provider_verifications (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          TEXT NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  kind             TEXT NOT NULL CHECK (kind IN ('id', 'care')),
  -- id:   national_id | passport | alien_id
  -- care: certificate (DCI Certificate of Good Conduct) | receipt (eCitizen
  --       application receipt, accepted for 30 days)
  document_type    TEXT NOT NULL,
  -- Object paths in the private 'provider-verifications' bucket, each under
  -- '<user_id>/'. ID: front, back, selfie (passport: photo page, selfie).
  files            TEXT[] NOT NULL,
  status           TEXT NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'approved', 'rejected')),
  submitted_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reviewed_at      TIMESTAMPTZ,
  reviewed_by      TEXT,          -- admin_users.id of the reviewer
  rejection_reason TEXT,
  -- Approved receipts only: when the provisional Care check ends.
  expires_at       TIMESTAMPTZ,
  -- When the backend deleted the images (30 days after the decision).
  files_deleted_at TIMESTAMPTZ,
  CONSTRAINT provider_verifications_document_type_check CHECK (
    (kind = 'id'   AND document_type IN ('national_id', 'passport', 'alien_id')) OR
    (kind = 'care' AND document_type IN ('certificate', 'receipt'))
  ),
  CONSTRAINT provider_verifications_files_check
    CHECK (cardinality(files) BETWEEN 1 AND 4),
  CONSTRAINT provider_verifications_reviewed_check
    CHECK (status = 'pending' OR (reviewed_at IS NOT NULL AND reviewed_by IS NOT NULL)),
  CONSTRAINT provider_verifications_rejection_check
    CHECK (status <> 'rejected' OR nullif(btrim(rejection_reason), '') IS NOT NULL),
  CONSTRAINT provider_verifications_receipt_expiry_check
    CHECK (NOT (status = 'approved' AND document_type = 'receipt') OR expires_at IS NOT NULL)
);

COMMENT ON TABLE public.provider_verifications IS
  'Provider ID and Care check submissions. Service role only; the app reads its own status through my_verification_status(). Migration 135.';

-- One submission of each kind in review at a time.
CREATE UNIQUE INDEX IF NOT EXISTS uq_provider_verifications_one_pending
  ON public.provider_verifications (user_id, kind) WHERE status = 'pending';
-- The admin review queue, oldest first.
CREATE INDEX IF NOT EXISTS idx_provider_verifications_queue
  ON public.provider_verifications (submitted_at) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_provider_verifications_user
  ON public.provider_verifications (user_id, kind, status);
-- The image purge.
CREATE INDEX IF NOT EXISTS idx_provider_verifications_purge
  ON public.provider_verifications (reviewed_at)
  WHERE files_deleted_at IS NULL AND status IN ('approved', 'rejected');

ALTER TABLE public.provider_verifications ENABLE ROW LEVEL SECURITY;
-- No policies: clients read and write nothing here directly.
REVOKE ALL ON public.provider_verifications FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.provider_verifications TO service_role;

-- =============================================================================
-- §3  What a provider currently holds
-- =============================================================================
-- Derived from the submissions every time, so an expired receipt stops counting
-- the moment it expires without any job having to run.
--   id_verified:  an approved ID check.
--   care_status:  'checked' (ID + approved certificate), 'pending' (ID + an
--                 approved receipt that has not expired) or 'none'.
CREATE OR REPLACE FUNCTION public.provider_vetting_state(p_user_id text)
RETURNS TABLE (id_verified boolean, care_status text, care_expires_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH approved AS (
    SELECT kind, document_type, expires_at
      FROM public.provider_verifications
     WHERE user_id = p_user_id AND status = 'approved'
  ), s AS (
    SELECT
      EXISTS (SELECT 1 FROM approved WHERE kind = 'id')                                   AS id_ok,
      EXISTS (SELECT 1 FROM approved WHERE kind = 'care' AND document_type = 'certificate') AS cert_ok,
      (SELECT max(expires_at) FROM approved
        WHERE kind = 'care' AND document_type = 'receipt' AND expires_at > now())         AS receipt_until
  )
  SELECT
    s.id_ok,
    CASE
      WHEN s.id_ok AND s.cert_ok                       THEN 'checked'
      WHEN s.id_ok AND s.receipt_until IS NOT NULL     THEN 'pending'
      ELSE 'none'
    END,
    CASE WHEN s.id_ok AND NOT s.cert_ok THEN s.receipt_until END
  FROM s
$$;

-- Does this provider hold what a tier needs? p_allow_pending: a Care check on a
-- receipt counts (offering care work) or not (applying, being hired).
CREATE OR REPLACE FUNCTION public.provider_meets_vetting(p_user_id text, p_tier text, p_allow_pending boolean)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v RECORD;
BEGIN
  IF p_tier IS NULL THEN
    RETURN true;
  END IF;
  IF nullif(btrim(coalesce(p_user_id, '')), '') IS NULL THEN
    RETURN false;
  END IF;
  SELECT * INTO v FROM public.provider_vetting_state(p_user_id);
  IF p_tier = 'id' THEN
    RETURN coalesce(v.id_verified, false);
  ELSIF p_tier = 'care' THEN
    RETURN v.care_status = 'checked' OR (p_allow_pending AND v.care_status = 'pending');
  END IF;
  -- An unknown tier is a configuration error: refuse rather than wave through.
  RETURN false;
END;
$$;

-- For one listing: may it be offered, and with which label / hide time?
CREATE OR REPLACE FUNCTION public.vetting_post_flags(p_author text, p_type text, p_category text)
RETURNS TABLE (allowed boolean, tier text, label text, hide_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tier  text;
  v_state RECORD;
BEGIN
  IF p_type IS DISTINCT FROM 'offer' THEN
    RETURN QUERY SELECT true, NULL::text, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  v_tier := public.vetting_tier_for_category(p_category);
  IF v_tier IS NULL OR public.provider_meets_vetting(p_author, v_tier, false) THEN
    RETURN QUERY SELECT true, v_tier, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF v_tier = 'care' THEN
    SELECT * INTO v_state FROM public.provider_vetting_state(p_author);
    IF v_state.care_status = 'pending' THEN
      RETURN QUERY SELECT true, v_tier, 'certificate_pending'::text, v_state.care_expires_at;
      RETURN;
    END IF;
  END IF;
  RETURN QUERY SELECT false, v_tier, 'not_verified'::text, NULL::timestamptz;
END;
$$;

-- =============================================================================
-- §4  Listings: label and hide time
-- =============================================================================

ALTER TABLE public.posts
  -- What the feed shows next to a listing whose author has not completed the
  -- category's check: 'certificate_pending' | 'not_verified'. NULL = nothing.
  ADD COLUMN IF NOT EXISTS vetting_label   TEXT
    CHECK (vetting_label IS NULL OR vetting_label IN ('certificate_pending', 'not_verified')),
  -- When the sweep hides the listing unless the author is verified by then.
  ADD COLUMN IF NOT EXISTS vetting_hide_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_posts_vetting_hide_due
  ON public.posts (vetting_hide_at)
  WHERE vetting_hide_at IS NOT NULL AND archived_at IS NULL;

COMMENT ON COLUMN public.posts.vetting_label IS
  'Provider vetting label shown with the listing: certificate_pending | not_verified | NULL. Set by Help24 only (migration 135).';
COMMENT ON COLUMN public.posts.vetting_hide_at IS
  'When the vetting sweep hides this listing (archived_by = ''vetting'') unless its author holds the category''s check by then. Migration 135.';

-- =============================================================================
-- §5  Enforcement
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_posts_vetting_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  f RECORD;
BEGIN
  -- The backend and migrations set these columns themselves (sweep, review).
  IF public.moderation_caller_is_trusted() THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- A listing Help24 hid for verification reopens when the author is
    -- verified, not when the author says so.
    IF OLD.archived_by = 'vetting'
       AND (NEW.archived_at IS DISTINCT FROM OLD.archived_at
            OR NEW.archived_by IS DISTINCT FROM OLD.archived_by) THEN
      RAISE EXCEPTION 'HELP24_VERIFICATION_REQUIRED: this listing reopens when your verification is approved'
        USING ERRCODE = '42501',
              DETAIL  = coalesce(public.vetting_tier_for_category(OLD.category), ''),
              HINT    = 'Complete your verification in Help24 to reopen this listing.';
    END IF;
  END IF;

  IF NEW.archived_by = 'vetting'
     AND (TG_OP = 'INSERT' OR OLD.archived_by IS DISTINCT FROM 'vetting') THEN
    RAISE EXCEPTION 'HELP24_VERIFICATION_REQUIRED: only Help24 can hide a listing for verification'
      USING ERRCODE = '42501';
  END IF;

  -- Only re-judge when what the check depends on changes, or a listing the
  -- author archived is published again. Editing the title of a listing keeps
  -- its label and clock.
  IF TG_OP = 'UPDATE'
     AND NEW.type           IS NOT DISTINCT FROM OLD.type
     AND NEW.category       IS NOT DISTINCT FROM OLD.category
     AND NEW.author_user_id IS NOT DISTINCT FROM OLD.author_user_id
     AND NOT (OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL) THEN
    NEW.vetting_label   := OLD.vetting_label;
    NEW.vetting_hide_at := OLD.vetting_hide_at;
    RETURN NEW;
  END IF;

  SELECT * INTO f FROM public.vetting_post_flags(NEW.author_user_id, NEW.type, NEW.category);

  IF NOT f.allowed THEN
    RAISE EXCEPTION 'HELP24_VERIFICATION_REQUIRED: %',
      CASE f.tier WHEN 'care' THEN 'offering this work needs a Care check'
                  ELSE 'offering this work needs an ID check' END
      USING ERRCODE = '42501',
            DETAIL  = f.tier,
            HINT    = 'Verify your identity in Help24, then post again.';
  END IF;

  NEW.vetting_label   := f.label;
  NEW.vetting_hide_at := f.hide_at;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_posts_vetting_guard ON public.posts;
-- Named to fire after trg_posts_moderation_guard (BEFORE triggers run in name
-- order): a restricted account is refused by moderation first.
CREATE TRIGGER trg_posts_vetting_guard
  BEFORE INSERT OR UPDATE ON public.posts
  FOR EACH ROW EXECUTE FUNCTION public.fn_posts_vetting_guard();

CREATE OR REPLACE FUNCTION public.fn_applications_vetting_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_type     text;
  v_category text;
  v_tier     text;
BEGIN
  IF public.moderation_caller_is_trusted() THEN
    RETURN NEW;
  END IF;

  SELECT p.type, p.category INTO v_type, v_category
    FROM public.posts p WHERE p.id = NEW.post_id;

  -- Requests and jobs are where a provider applies to do the work.
  IF v_type NOT IN ('request', 'job') THEN
    RETURN NEW;
  END IF;

  v_tier := public.vetting_tier_for_category(v_category);
  IF v_tier IS NOT NULL
     AND NOT public.provider_meets_vetting(NEW.applicant_user_id, v_tier, false) THEN
    RAISE EXCEPTION 'HELP24_VERIFICATION_REQUIRED: %',
      CASE v_tier WHEN 'care' THEN 'applying for this work needs a completed Care check'
                  ELSE 'applying for this work needs an ID check' END
      USING ERRCODE = '42501',
            DETAIL  = v_tier,
            HINT    = 'Verify your identity in Help24, then apply again.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_applications_vetting_guard ON public.applications;
CREATE TRIGGER trg_applications_vetting_guard
  BEFORE INSERT ON public.applications
  FOR EACH ROW EXECUTE FUNCTION public.fn_applications_vetting_guard();

-- =============================================================================
-- §6  Keeping listings in step with a provider's checks
-- =============================================================================
-- Re-judges every offer of one author in a vetted category:
--   * allowed now  -> label/hide time recomputed; a listing hidden for
--                     verification is reopened;
--   * not allowed  -> label 'not_verified'; hidden at once unless a hide time
--                     still lies ahead (the 14-day notice for older listings).
-- Returns how many listings changed.
CREATE OR REPLACE FUNCTION public.vetting_refresh_author_posts(p_user_id text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r       RECORD;
  f       RECORD;
  v_count integer := 0;
BEGIN
  FOR r IN
    SELECT p.id, p.type, p.category, p.archived_at, p.archived_by, p.vetting_label, p.vetting_hide_at
      FROM public.posts p
     WHERE p.author_user_id = p_user_id
       AND p.type = 'offer'
       AND public.vetting_tier_for_category(p.category) IS NOT NULL
       AND (p.archived_at IS NULL OR p.archived_by = 'vetting')
     FOR UPDATE
  LOOP
    SELECT * INTO f FROM public.vetting_post_flags(p_user_id, r.type, r.category);

    IF f.allowed THEN
      IF r.archived_by = 'vetting'
         OR r.vetting_label IS DISTINCT FROM f.label
         OR r.vetting_hide_at IS DISTINCT FROM f.hide_at THEN
        UPDATE public.posts
           SET vetting_label   = f.label,
               vetting_hide_at = f.hide_at,
               archived_at     = CASE WHEN archived_by = 'vetting' THEN NULL ELSE archived_at END,
               archived_by     = CASE WHEN archived_by = 'vetting' THEN NULL ELSE archived_by END
         WHERE id = r.id;
        v_count := v_count + 1;
      END IF;
    ELSIF r.archived_at IS NULL THEN
      IF r.vetting_hide_at IS NOT NULL AND r.vetting_hide_at > now() AND r.vetting_label = 'not_verified' THEN
        CONTINUE;  -- still inside its notice period
      END IF;
      UPDATE public.posts
         SET vetting_label   = 'not_verified',
             vetting_hide_at = NULL,
             archived_at     = now(),
             archived_by     = 'vetting'
       WHERE id = r.id;
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

-- The backend runs this every few minutes. Hides listings whose notice or
-- pending-certificate window has run out (and reopens nothing early: an author
-- verified in the meantime was already refreshed by the review).
CREATE OR REPLACE FUNCTION public.vetting_sweep()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_author text;
  v_total  integer := 0;
BEGIN
  FOR v_author IN
    SELECT DISTINCT p.author_user_id
      FROM public.posts p
     WHERE p.vetting_hide_at IS NOT NULL
       AND p.vetting_hide_at <= now()
       AND p.archived_at IS NULL
       AND p.author_user_id IS NOT NULL
  LOOP
    -- A due listing has its clock cleared so the refresh judges it now.
    UPDATE public.posts
       SET vetting_hide_at = NULL
     WHERE author_user_id = v_author
       AND vetting_hide_at IS NOT NULL
       AND vetting_hide_at <= now()
       AND archived_at IS NULL;
    v_total := v_total + public.vetting_refresh_author_posts(v_author);
  END LOOP;
  RETURN v_total;
END;
$$;

-- =============================================================================
-- §7  The app's door: submit, and read your own status
-- =============================================================================

CREATE OR REPLACE FUNCTION public.submit_provider_verification(
  p_kind text, p_document_type text, p_files text[]
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    text;
  v_file   text;
  v_found  integer;
  v_id     uuid;
  v_expect integer;
BEGIN
  v_uid := nullif(btrim(coalesce(
    coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'user_id', '')), '');
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'HELP24_VERIFICATION_INVALID: sign in to verify' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_uid) THEN
    RAISE EXCEPTION 'HELP24_VERIFICATION_INVALID: finish setting up your profile first' USING ERRCODE = '22023';
  END IF;

  -- A suspended or banned account cannot post (migration 114's capability
  -- map), so there is nothing for it to be verified for.
  IF public.moderation_denial(v_uid, 'post') IS NOT NULL THEN
    RAISE EXCEPTION 'HELP24_ACCOUNT_RESTRICTED: this account cannot be verified right now' USING ERRCODE = '42501';
  END IF;

  IF p_kind NOT IN ('id', 'care')
     OR (p_kind = 'id'   AND p_document_type NOT IN ('national_id', 'passport', 'alien_id'))
     OR (p_kind = 'care' AND p_document_type NOT IN ('certificate', 'receipt')) THEN
    RAISE EXCEPTION 'HELP24_VERIFICATION_INVALID: unknown document type' USING ERRCODE = '22023';
  END IF;

  -- Front, back and a selfie holding the card; a passport has one photo page.
  v_expect := CASE
    WHEN p_document_type IN ('national_id', 'alien_id') THEN 3
    WHEN p_document_type = 'passport'                    THEN 2
    ELSE NULL END;
  IF p_files IS NULL OR cardinality(p_files) = 0 OR cardinality(p_files) > 4
     OR (v_expect IS NOT NULL AND cardinality(p_files) <> v_expect) THEN
    RAISE EXCEPTION 'HELP24_VERIFICATION_INVALID: wrong number of photos for this document' USING ERRCODE = '22023';
  END IF;

  FOREACH v_file IN ARRAY p_files LOOP
    IF v_file IS NULL
       OR left(v_file, length(v_uid) + 1) <> v_uid || '/'
       OR substr(v_file, length(v_uid) + 2) !~ '^[A-Za-z0-9._-]{1,120}$' THEN
      RAISE EXCEPTION 'HELP24_VERIFICATION_INVALID: photos must be your own uploads' USING ERRCODE = '42501';
    END IF;
  END LOOP;

  -- Every file must really be in the private bucket (skipped where there is no
  -- storage schema, i.e. the local test replica).
  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE 'SELECT count(DISTINCT name) FROM storage.objects WHERE bucket_id = $1 AND name = ANY($2)'
      INTO v_found USING 'provider-verifications', p_files;
    IF v_found <> cardinality(p_files) THEN
      RAISE EXCEPTION 'HELP24_VERIFICATION_INVALID: a photo did not finish uploading — try again' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_kind = 'id' AND EXISTS (
    SELECT 1 FROM public.provider_verifications
     WHERE user_id = v_uid AND kind = 'id' AND status = 'approved') THEN
    RAISE EXCEPTION 'HELP24_VERIFICATION_INVALID: your ID is already verified' USING ERRCODE = '22023';
  END IF;

  IF p_kind = 'care' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.provider_verifications
       WHERE user_id = v_uid AND kind = 'id' AND status IN ('pending', 'approved')) THEN
      RAISE EXCEPTION 'HELP24_VERIFICATION_INVALID: send your ID first — the Care check includes it' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.provider_verifications
       WHERE user_id = v_uid AND kind = 'care' AND document_type = 'certificate' AND status = 'approved') THEN
      RAISE EXCEPTION 'HELP24_VERIFICATION_INVALID: your Care check is already complete' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.provider_verifications
     WHERE user_id = v_uid AND kind = p_kind AND status = 'pending') THEN
    RAISE EXCEPTION 'HELP24_VERIFICATION_PENDING: we are still reviewing what you sent' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.provider_verifications (user_id, kind, document_type, files)
  VALUES (v_uid, p_kind, p_document_type, p_files)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- The signed-in member's own status, for the app's verification screen.
-- Never returns file paths or who reviewed.
CREATE OR REPLACE FUNCTION public.my_verification_status()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   text;
  v_state RECORD;
BEGIN
  v_uid := nullif(btrim(coalesce(
    coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'user_id', '')), '');
  IF v_uid IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_state FROM public.provider_vetting_state(v_uid);

  RETURN jsonb_build_object(
    'id_verified',     v_state.id_verified,
    'care_status',     v_state.care_status,
    'care_expires_at', v_state.care_expires_at,
    'latest', (
      SELECT coalesce(jsonb_object_agg(kind, row_json), '{}'::jsonb)
        FROM (
          SELECT DISTINCT ON (kind)
                 kind,
                 jsonb_build_object(
                   'document_type',    document_type,
                   'status',           status,
                   'submitted_at',     submitted_at,
                   'reviewed_at',      reviewed_at,
                   'rejection_reason', rejection_reason,
                   'expires_at',       expires_at
                 ) AS row_json
            FROM public.provider_verifications
           WHERE user_id = v_uid
           ORDER BY kind, submitted_at DESC
        ) latest
    ),
    'tiers', (
      SELECT coalesce(jsonb_object_agg(c.name, c.vetting_tier), '{}'::jsonb)
        FROM public.categories c
       WHERE c.vetting_tier IS NOT NULL AND c.active
    )
  );
END;
$$;

-- =============================================================================
-- §8  The admin's door: review (backend, service role)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.review_provider_verification(
  p_id uuid, p_decision text, p_reason text, p_reviewer text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row     public.provider_verifications%ROWTYPE;
  v_changed integer;
BEGIN
  IF p_decision NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'HELP24_VERIFICATION_INVALID: decision must be approve or reject' USING ERRCODE = '22023';
  END IF;
  IF nullif(btrim(coalesce(p_reviewer, '')), '') IS NULL THEN
    RAISE EXCEPTION 'HELP24_VERIFICATION_INVALID: reviewer required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row FROM public.provider_verifications WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_VERIFICATION_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;
  IF v_row.status <> 'pending' THEN
    RAISE EXCEPTION 'HELP24_VERIFICATION_ALREADY_REVIEWED: this submission was already %', v_row.status
      USING ERRCODE = '22023';
  END IF;

  IF p_decision = 'reject' THEN
    IF nullif(btrim(coalesce(p_reason, '')), '') IS NULL THEN
      RAISE EXCEPTION 'HELP24_VERIFICATION_INVALID: give the provider a reason' USING ERRCODE = '22023';
    END IF;
    UPDATE public.provider_verifications
       SET status = 'rejected', reviewed_at = now(), reviewed_by = p_reviewer,
           rejection_reason = btrim(p_reason)
     WHERE id = p_id
     RETURNING * INTO v_row;
  ELSE
    -- The Care check is the ID check plus the certificate: the ID comes first.
    IF v_row.kind = 'care' AND NOT EXISTS (
      SELECT 1 FROM public.provider_verifications
       WHERE user_id = v_row.user_id AND kind = 'id' AND status = 'approved') THEN
      RAISE EXCEPTION 'HELP24_VERIFICATION_INVALID: approve this provider''s ID first' USING ERRCODE = '22023';
    END IF;
    UPDATE public.provider_verifications
       SET status = 'approved', reviewed_at = now(), reviewed_by = p_reviewer,
           rejection_reason = NULL,
           expires_at = CASE WHEN document_type = 'receipt' THEN now() + interval '30 days' END
     WHERE id = p_id
     RETURNING * INTO v_row;
  END IF;

  -- The ranking signal and badge (migration 093) follow the ID check.
  UPDATE public.users u
     SET is_verified = EXISTS (
           SELECT 1 FROM public.provider_verifications v
            WHERE v.user_id = u.id AND v.kind = 'id' AND v.status = 'approved')
   WHERE u.id = v_row.user_id;

  v_changed := public.vetting_refresh_author_posts(v_row.user_id);

  RETURN jsonb_build_object(
    'id',            v_row.id,
    'user_id',       v_row.user_id,
    'kind',          v_row.kind,
    'document_type', v_row.document_type,
    'status',        v_row.status,
    'expires_at',    v_row.expires_at,
    'listings_changed', v_changed
  );
END;
$$;

-- =============================================================================
-- §9  What everyone sees: the outcome only
-- =============================================================================
-- Columns APPENDED to migration 123's view (CREATE OR REPLACE allows nothing
-- else). It runs with its owner's rights, so it can read the submissions table
-- clients cannot; it exposes two outcomes and nothing about the documents.
CREATE OR REPLACE VIEW public.public_profiles AS
SELECT
  u.id,
  u.name,
  coalesce(nullif(u.avatar_url, ''), nullif(u.profile_image, '')) AS avatar_url,
  u.phone_number IS NOT NULL AND u.phone_number <> '' AS has_phone,
  nullif(u.profile_image, '') AS profile_image,
  u.profession,
  u.bio,
  u.created_at,
  u.last_seen,
  u.is_online,
  -- "ID verified"
  coalesce(u.is_verified, false) AS id_verified,
  -- "Care checked" ('checked') / "Certificate pending" ('pending') / NULL
  CASE
    WHEN NOT coalesce(u.is_verified, false) THEN NULL
    WHEN EXISTS (SELECT 1 FROM public.provider_verifications v
                  WHERE v.user_id = u.id AND v.kind = 'care'
                    AND v.document_type = 'certificate' AND v.status = 'approved') THEN 'checked'
    WHEN EXISTS (SELECT 1 FROM public.provider_verifications v
                  WHERE v.user_id = u.id AND v.kind = 'care'
                    AND v.document_type = 'receipt' AND v.status = 'approved'
                    AND v.expires_at > now()) THEN 'pending'
  END AS care_status
FROM public.users u;

GRANT SELECT ON public.public_profiles TO anon, authenticated;

-- =============================================================================
-- §10  Listings posted before vetting: 14 days' notice
-- =============================================================================
-- Only rows not yet labelled, so a re-run never restarts a clock.
UPDATE public.posts p
   SET vetting_label   = 'not_verified',
       vetting_hide_at = now() + interval '14 days'
 WHERE p.type = 'offer'
   AND p.archived_at IS NULL
   AND p.vetting_label IS NULL
   AND public.vetting_tier_for_category(p.category) IS NOT NULL
   AND NOT public.provider_meets_vetting(p.author_user_id, public.vetting_tier_for_category(p.category), true);

-- =============================================================================
-- §11  Grants
-- =============================================================================

REVOKE ALL ON FUNCTION public.vetting_tier_for_category(text)                      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provider_vetting_state(text)                         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provider_meets_vetting(text, text, boolean)          FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.vetting_post_flags(text, text, text)                 FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_posts_vetting_guard()                             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_applications_vetting_guard()                      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.vetting_refresh_author_posts(text)                   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.vetting_sweep()                                      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.review_provider_verification(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.submit_provider_verification(text, text, text[])     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.my_verification_status()                             FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.provider_vetting_state(text)                         TO service_role;
GRANT EXECUTE ON FUNCTION public.provider_meets_vetting(text, text, boolean)          TO service_role;
GRANT EXECUTE ON FUNCTION public.vetting_tier_for_category(text)                      TO service_role;
GRANT EXECUTE ON FUNCTION public.vetting_refresh_author_posts(text)                   TO service_role;
GRANT EXECUTE ON FUNCTION public.vetting_sweep()                                      TO service_role;
GRANT EXECUTE ON FUNCTION public.review_provider_verification(uuid, text, text, text) TO service_role;
-- The two functions the app may call. Both read the caller's own JWT and
-- cannot be pointed at anyone else.
GRANT EXECUTE ON FUNCTION public.submit_provider_verification(text, text, text[])     TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_verification_status()                             TO authenticated;
