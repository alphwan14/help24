-- =============================================================================
-- Migration 145: changing a listing's type after it is posted
-- =============================================================================
-- People pick the wrong type. "Edger here anyone in need of plumber" went up
-- as a Request; it is an offer. The app now lets the AUTHOR switch a request to
-- an offer and back, and an admin can RECLASSIFY a listing from the console.
--
-- Before this migration nothing stopped a type change and nothing recorded
-- one: posts_update_owner (076) lets the author write any column, so an owner
-- could already flip the type of a paid, assigned job. The app never offered
-- it, so nobody did. Now that it does, the rules live here, next to the data.
--
--   1. post_type_changes            one row per change, whoever made it.
--   2. trg_posts_type_change        BEFORE UPDATE OF type: the author's rules,
--                                   and the clean-up every change needs.
--   3. trg_posts_type_change_log    AFTER UPDATE OF type: the record.
--   4. admin_reclassify_post(...)   the console's path. service_role only.
--
-- ── The author's rules (any caller that is not service_role / postgres) ────
--   * request <-> offer only. A job has its own form (employment type, salary,
--     start date), so turning one into or out of a job is not a one-tap switch.
--   * the listing is open, nobody has been selected, and it is not archived.
--   * nobody has responded yet. An application was an answer to a request;
--     re-labelling the listing under the people who answered it changes what
--     they said yes to. An admin can still reclassify it.
-- The vetting guard (135, trg_posts_vetting_guard) already re-judges a listing
-- whose type changes, and runs AFTER this trigger (triggers fire in name
-- order), so an unverified author still cannot turn a request into an offer of
-- care work. The moderation guard (116) runs BEFORE it and refuses any change
-- to a listing Help24 hid.
--
-- ── Clean-up on every change, whoever makes it ─────────────────────────────
--   to offer or job  urgency 'flexible', is_urgent false, urgent_expires_at
--                    null. Offers and jobs never carry urgency (the app's
--                    kOfferUrgency / kJobUrgency); a stale "Urgent" would keep
--                    an offer in the urgent strip.
--   reserved keys    each journey writes one reserved answer into attributes:
--                    '_when' (request), '_availability' (offer), '_start'
--                    (job). The ones that belong to another journey are
--                    dropped, so a card never shows a request's "Today" on an
--                    offer. Category answers are kept.
--   employment_type  required for a job (017's trigger refuses without it)
--                    and nulled by that trigger for everything else.
--
-- ── Admin path ─────────────────────────────────────────────────────────────
-- admin_reclassify_post runs as service_role, which the vetting and moderation
-- guards trust and skip. So it re-checks both itself: a moderated listing is
-- refused, and the vetting verdict for the new type is computed with the same
-- vetting_post_flags the guard uses and written onto the row. Any active admin
-- may use it (the console shows it to support agents and up), with a reason.
--
-- Nothing here changes a listing that is not being re-typed: both triggers are
-- UPDATE OF type and return at once when the value did not change.
--
-- Rollback:
--   DROP TRIGGER IF EXISTS trg_posts_type_change ON public.posts;
--   DROP TRIGGER IF EXISTS trg_posts_type_change_log ON public.posts;
--   DROP FUNCTION IF EXISTS public.admin_reclassify_post(uuid, uuid, text, text, text);
--   DROP FUNCTION IF EXISTS public.fn_posts_type_change();
--   DROP FUNCTION IF EXISTS public.fn_posts_type_change_log();
--   DROP TABLE IF EXISTS public.post_type_changes;
-- =============================================================================

BEGIN;

-- ── 1. The record ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.post_type_changes (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id         uuid        NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
  from_type       text        NOT NULL,
  to_type         text        NOT NULL,
  -- owner: the author, from the app. admin: admin_reclassify_post.
  -- system: any other trusted write (a migration, a backend fix-up).
  changed_by_kind text        NOT NULL CHECK (changed_by_kind IN ('owner', 'admin', 'system')),
  -- The author's uid for 'owner', admin_users.id for 'admin', null for 'system'.
  changed_by      text,
  -- For 'admin': who, as they were at the time (an admin can be removed later).
  admin_email     text,
  reason          text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS post_type_changes_post_idx
  ON public.post_type_changes (post_id, created_at DESC);

-- Read by the admin console through service_role only. Nobody else reads it.
ALTER TABLE public.post_type_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.post_type_changes FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.post_type_changes TO service_role;

-- ── 2. The rules and the clean-up ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_posts_type_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.type IS NOT DISTINCT FROM OLD.type THEN
    RETURN NEW;
  END IF;

  IF NOT public.moderation_caller_is_trusted() THEN
    IF OLD.type NOT IN ('request', 'offer') OR NEW.type NOT IN ('request', 'offer') THEN
      RAISE EXCEPTION 'HELP24_TYPE_CHANGE_REFUSED: only a request and an offer can be switched'
        USING ERRCODE = '42501';
    END IF;
    IF OLD.status IS DISTINCT FROM 'open' OR OLD.selected_provider_id IS NOT NULL THEN
      RAISE EXCEPTION 'HELP24_TYPE_CHANGE_REFUSED: this listing already has a provider'
        USING ERRCODE = '42501';
    END IF;
    IF OLD.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'HELP24_TYPE_CHANGE_REFUSED: this listing is closed'
        USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM public.applications a WHERE a.post_id = OLD.id) THEN
      RAISE EXCEPTION 'HELP24_TYPE_CHANGE_REFUSED: people have already responded to it'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  IF NEW.type IN ('offer', 'job') THEN
    NEW.urgency           := 'flexible';
    NEW.is_urgent         := false;
    NEW.urgent_expires_at := NULL;
  END IF;

  NEW.attributes := coalesce(NEW.attributes, '{}'::jsonb) - CASE NEW.type
    WHEN 'request' THEN ARRAY['_availability', '_start']
    WHEN 'offer'   THEN ARRAY['_when', '_start']
    WHEN 'job'     THEN ARRAY['_when', '_availability']
    ELSE ARRAY[]::text[]
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_posts_type_change ON public.posts;
CREATE TRIGGER trg_posts_type_change
  BEFORE UPDATE OF type ON public.posts
  FOR EACH ROW EXECUTE FUNCTION public.fn_posts_type_change();

-- ── 3. The record of each change ────────────────────────────────────────────
-- AFTER, so only a change that every guard accepted is recorded.
CREATE OR REPLACE FUNCTION public.fn_posts_type_change_log()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_trusted boolean := public.moderation_caller_is_trusted();
  v_admin   text    := nullif(current_setting('help24.reclassify_admin_id', true), '');
  v_reason  text    := nullif(current_setting('help24.reclassify_reason', true), '');
  v_uid     text    := nullif(btrim(coalesce(
    coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'user_id', '')), '');
BEGIN
  IF NEW.type IS NOT DISTINCT FROM OLD.type THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.post_type_changes (post_id, from_type, to_type, changed_by_kind, changed_by, admin_email, reason)
  VALUES (
    NEW.id,
    OLD.type,
    NEW.type,
    CASE WHEN NOT v_trusted THEN 'owner' WHEN v_admin IS NOT NULL THEN 'admin' ELSE 'system' END,
    CASE WHEN NOT v_trusted THEN v_uid WHEN v_admin IS NOT NULL THEN v_admin ELSE NULL END,
    CASE WHEN v_trusted AND v_admin IS NOT NULL
         THEN (SELECT a.email FROM public.admin_users a WHERE a.id::text = v_admin)
         ELSE NULL END,
    CASE WHEN v_trusted THEN v_reason ELSE NULL END
  );
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_posts_type_change_log ON public.posts;
CREATE TRIGGER trg_posts_type_change_log
  AFTER UPDATE OF type ON public.posts
  FOR EACH ROW EXECUTE FUNCTION public.fn_posts_type_change_log();

-- ── 4. The console's path ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_reclassify_post(
  p_admin_id        uuid,
  p_post_id         uuid,
  p_type            text,
  p_employment_type text,
  p_reason          text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin  public.admin_users%ROWTYPE;
  v_post   public.posts%ROWTYPE;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_emp    text := nullif(btrim(coalesce(p_employment_type, '')), '');
  v_flags  RECORD;
  v_apps   integer;
BEGIN
  PERFORM public.moderation_assert_trusted();
  v_admin := public.moderation_require_admin(p_admin_id);

  IF p_type IS NULL OR p_type NOT IN ('request', 'offer', 'job') THEN
    RAISE EXCEPTION 'HELP24_RECLASSIFY_INVALID: choose request, offer or job' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_reason) < 5 OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'HELP24_RECLASSIFY_INVALID: give a reason, in 5 to 500 characters' USING ERRCODE = '22023';
  END IF;
  IF p_type = 'job' AND (v_emp IS NULL OR v_emp NOT IN ('full_time', 'part_time', 'contract', 'temporary')) THEN
    RAISE EXCEPTION 'HELP24_RECLASSIFY_INVALID: a job needs an employment type' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_post FROM public.posts WHERE id = p_post_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_RECLASSIFY_NOT_FOUND: no such listing' USING ERRCODE = '22023';
  END IF;
  IF v_post.archived_by = 'moderation' THEN
    RAISE EXCEPTION 'HELP24_RECLASSIFY_REFUSED: this listing was hidden by moderation' USING ERRCODE = '42501';
  END IF;
  IF v_post.status IS DISTINCT FROM 'open' OR v_post.selected_provider_id IS NOT NULL THEN
    RAISE EXCEPTION 'HELP24_RECLASSIFY_REFUSED: this listing already has a provider, so its type stays' USING ERRCODE = '42501';
  END IF;
  IF v_post.type = p_type THEN
    RAISE EXCEPTION 'HELP24_RECLASSIFY_REFUSED: it is already a %', p_type USING ERRCODE = '22023';
  END IF;

  -- The vetting guard skips service_role, so its verdict is taken here.
  SELECT * INTO v_flags FROM public.vetting_post_flags(v_post.author_user_id, p_type, v_post.category);
  IF NOT v_flags.allowed THEN
    RAISE EXCEPTION 'HELP24_RECLASSIFY_REFUSED: the author needs %',
      CASE v_flags.tier WHEN 'care' THEN 'a Care check to offer this work' ELSE 'an ID check to offer this work' END
      USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('help24.reclassify_admin_id', v_admin.id::text, true);
  PERFORM set_config('help24.reclassify_reason', v_reason, true);

  UPDATE public.posts
     SET type            = p_type,
         employment_type = CASE WHEN p_type = 'job' THEN v_emp ELSE NULL END,
         vetting_label   = v_flags.label,
         vetting_hide_at = v_flags.hide_at
   WHERE id = p_post_id;

  PERFORM set_config('help24.reclassify_admin_id', '', true);
  PERFORM set_config('help24.reclassify_reason', '', true);

  SELECT count(*) INTO v_apps FROM public.applications WHERE post_id = p_post_id;

  RETURN jsonb_build_object(
    'post_id', p_post_id,
    'from_type', v_post.type,
    'to_type', p_type,
    'applications', v_apps
  );
END;
$$;

REVOKE ALL ON FUNCTION public.fn_posts_type_change()                                FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_posts_type_change_log()                            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_reclassify_post(uuid, uuid, text, text, text)  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reclassify_post(uuid, uuid, text, text, text) TO service_role;

COMMIT;
