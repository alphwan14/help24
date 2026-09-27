-- =============================================================================
-- 115 — Trust & Safety, part 2 of 3: the only way to change moderation state
-- =============================================================================
-- NOT APPLIED. Requires 114. Tested on the local replica described in 114.
--
-- Six functions, and they are the ENTIRE write surface of moderation:
--
--   moderation_apply_sanction      warn / suspend / ban / restrict messaging /
--                                  restrict marketplace — optionally hiding the
--                                  account's open listings and closing the
--                                  report that prompted it
--   moderation_lift_restriction    end a sanction early (an appeal upheld, a
--                                  mistake corrected)
--   moderation_update_report       triage: status, severity, assignment, reopen
--   moderation_resolve_report      close a report as resolved or dismissed
--   moderation_add_note            an internal note on a report or an account
--   moderation_set_content_state   hide or restore one listing or one message
--
-- EVERY ONE OF THEM writes its moderation_actions row in the same transaction
-- as the change it describes. There is no code path that changes a sanction,
-- a report's status or a hidden listing without the ledger saying who did it,
-- in what role, why, and what the account looked like before and after —
-- because 114 revoked direct writes to all of those, even from service_role.
--
-- WHERE AUTHORIZATION LIVES. These functions do not know the admin RBAC ladder
-- (support_agent < senior_admin < super_admin); the backend enforces it with
-- @Roles before calling, exactly as the disputes centre does. What these
-- functions DO enforce is everything that must hold however they are reached:
-- the caller is the backend or an owner connection (never the app's key), the
-- acting admin exists and is active, a reason is given, terms are sane, and the
-- admin's role AT THAT MOMENT is copied into the ledger — so "was this person
-- allowed to do this?" is answerable later from the row alone.
--
-- Rollback:
--   DROP FUNCTION IF EXISTS public.moderation_apply_sanction(uuid, text, text, text, text, timestamptz, uuid, boolean, boolean, text),
--     public.moderation_lift_restriction(uuid, uuid, text, text, text),
--     public.moderation_update_report(uuid, uuid, text, text, uuid, boolean, text, text),
--     public.moderation_resolve_report(uuid, uuid, text, text, text, text),
--     public.moderation_add_note(uuid, text, text, uuid, text),
--     public.moderation_set_content_state(uuid, text, text, text, text, text, uuid, text),
--     public.moderation_assert_trusted(), public.moderation_require_admin(uuid);
-- =============================================================================

BEGIN;

-- ── Shared guards ────────────────────────────────────────────────────────────

-- Belt and braces over the REVOKEs at the bottom of this file: even if EXECUTE
-- were ever granted to `authenticated` by mistake, the app's key still cannot
-- moderate anyone.
CREATE OR REPLACE FUNCTION public.moderation_assert_trusted()
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.moderation_caller_is_trusted() THEN
    RAISE EXCEPTION 'HELP24_MODERATION_FORBIDDEN: moderation is server-only' USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.moderation_require_admin(p_admin_id uuid)
RETURNS public.admin_users
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v public.admin_users%ROWTYPE;
BEGIN
  SELECT * INTO v FROM public.admin_users WHERE id = p_admin_id;
  IF NOT FOUND OR v.active IS NOT TRUE THEN
    RAISE EXCEPTION 'HELP24_ADMIN_INVALID: the acting admin is unknown or inactive' USING ERRCODE = '42501';
  END IF;
  RETURN v;
END;
$$;

-- =============================================================================
-- moderation_apply_sanction
-- =============================================================================
CREATE OR REPLACE FUNCTION public.moderation_apply_sanction(
  p_admin_id       uuid,
  p_user_id        text,
  p_kind           text,
  p_reason         text,
  p_internal_note  text        DEFAULT NULL,
  p_ends_at        timestamptz DEFAULT NULL,
  p_report_id      uuid        DEFAULT NULL,
  p_resolve_report boolean     DEFAULT false,
  p_hide_listings  boolean     DEFAULT false,
  p_request_id     text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin       public.admin_users%ROWTYPE;
  v_user        public.users%ROWTYPE;
  v_report      public.user_reports%ROWTYPE;
  v_reason      text := btrim(coalesce(p_reason, ''));
  v_note        text := nullif(btrim(coalesce(p_internal_note, '')), '');
  v_prev        jsonb;
  v_new         jsonb;
  v_restriction uuid;
  v_action      uuid;
  v_action_type text;
  v_superseded  uuid[] := '{}';
  v_hidden      uuid[] := '{}';
  v_resolved    boolean := false;
  r             record;
BEGIN
  PERFORM public.moderation_assert_trusted();
  v_admin := public.moderation_require_admin(p_admin_id);

  IF p_kind IS NULL OR p_kind NOT IN ('warning', 'suspension', 'ban', 'messaging', 'marketplace') THEN
    RAISE EXCEPTION 'HELP24_MODERATION_INVALID: unknown sanction %', p_kind USING ERRCODE = '22023';
  END IF;
  -- The reason is what the person is TOLD. "spam" is not a reason anyone can
  -- act on or contest; ten characters is the floor for a sentence.
  IF char_length(v_reason) < 10 OR char_length(v_reason) > 1000 THEN
    RAISE EXCEPTION 'HELP24_MODERATION_INVALID: a reason of 10 to 1000 characters is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_user FROM public.users WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_MODERATION_NOT_FOUND: account not found' USING ERRCODE = '22023';
  END IF;

  -- An admin never sanctions their own marketplace account: that is either a
  -- test, which belongs on a test account, or a conflict of interest.
  IF v_user.email IS NOT NULL AND btrim(v_user.email) <> ''
     AND lower(v_user.email) = lower(v_admin.email) THEN
    RAISE EXCEPTION 'HELP24_MODERATION_SELF: you cannot moderate your own account' USING ERRCODE = '42501';
  END IF;

  IF p_report_id IS NOT NULL THEN
    SELECT * INTO v_report FROM public.user_reports WHERE id = p_report_id FOR UPDATE;
    IF NOT FOUND OR v_report.reported_user_id <> p_user_id THEN
      RAISE EXCEPTION 'HELP24_MODERATION_INVALID: that report is not about this account' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Terms. A suspension must end, within a year; a ban must not. The two
  -- partial restrictions may be open-ended or dated.
  IF p_kind = 'suspension' THEN
    IF p_ends_at IS NULL OR p_ends_at < now() + interval '1 hour' OR p_ends_at > now() + interval '366 days' THEN
      RAISE EXCEPTION 'HELP24_MODERATION_INVALID: a suspension needs an end between 1 hour and 1 year from now'
        USING ERRCODE = '22023';
    END IF;
  ELSIF p_kind IN ('messaging', 'marketplace') THEN
    IF p_ends_at IS NOT NULL
       AND (p_ends_at < now() + interval '1 hour' OR p_ends_at > now() + interval '366 days') THEN
      RAISE EXCEPTION 'HELP24_MODERATION_INVALID: an end date must be between 1 hour and 1 year from now'
        USING ERRCODE = '22023';
    END IF;
  ELSIF p_ends_at IS NOT NULL THEN
    RAISE EXCEPTION 'HELP24_MODERATION_INVALID: a % takes no end date', p_kind USING ERRCODE = '22023';
  END IF;

  -- A second ban on a banned account is a double-click, not a decision.
  IF p_kind = 'ban' AND 'ban' = ANY (public.moderation_active_kinds(p_user_id)) THEN
    RAISE EXCEPTION 'HELP24_MODERATION_CONFLICT: this account is already banned' USING ERRCODE = '23505';
  END IF;

  IF p_hide_listings AND p_kind NOT IN ('suspension', 'ban', 'marketplace') THEN
    RAISE EXCEPTION 'HELP24_MODERATION_INVALID: listings can only be hidden with a suspension, ban or marketplace restriction'
      USING ERRCODE = '22023';
  END IF;

  v_prev := public.moderation_state_json(p_user_id);
  PERFORM set_config('help24.moderation_write', 'on', true);

  v_action_type := CASE p_kind
    WHEN 'warning'     THEN 'warning_issued'
    WHEN 'suspension'  THEN 'suspension_applied'
    WHEN 'ban'         THEN 'ban_applied'
    WHEN 'messaging'   THEN 'messaging_restricted'
    ELSE                    'marketplace_restricted'
  END;

  IF p_kind <> 'warning' THEN
    -- A new sanction REPLACES the one of its kind in force: a 7-day suspension
    -- extended to 30 is one suspension, not two overlapping ones. A ban also
    -- ends a running suspension. Each replacement is its own ledger row.
    FOR r IN
      SELECT ar.id, ar.kind
        FROM public.account_restrictions ar
       WHERE ar.user_id = p_user_id
         AND ar.lifted_at IS NULL
         AND ar.starts_at <= now()
         AND (ar.ends_at IS NULL OR ar.ends_at > now())
         AND (ar.kind = p_kind OR (p_kind = 'ban' AND ar.kind = 'suspension'))
       FOR UPDATE
    LOOP
      UPDATE public.account_restrictions
         SET lifted_at = now(), lifted_by = p_admin_id,
             lift_reason = 'Replaced by a new ' || p_kind || '.'
       WHERE id = r.id;

      INSERT INTO public.moderation_actions
        (target_user_id, action_type, admin_id, admin_email, admin_role, report_id,
         restriction_id, reason, previous_state, new_state, metadata, request_id)
      VALUES
        (p_user_id, 'restriction_lifted', v_admin.id, v_admin.email, v_admin.role, p_report_id,
         r.id, 'Replaced by a new ' || p_kind || '.', v_prev, public.moderation_state_json(p_user_id),
         jsonb_build_object('kind', r.kind, 'superseded_by', p_kind), p_request_id);

      v_superseded := v_superseded || r.id;
    END LOOP;

    INSERT INTO public.account_restrictions (user_id, kind, reason, ends_at, report_id, created_by)
    VALUES (p_user_id, p_kind, v_reason, p_ends_at, p_report_id, p_admin_id)
    RETURNING id INTO v_restriction;

    IF p_kind = 'ban' THEN
      UPDATE public.users SET is_banned = true WHERE id = p_user_id AND is_banned IS NOT TRUE;
    END IF;
  END IF;

  v_new := public.moderation_state_json(p_user_id);

  INSERT INTO public.moderation_actions
    (target_user_id, action_type, admin_id, admin_email, admin_role, report_id, restriction_id,
     reason, internal_note, previous_state, new_state, metadata, request_id)
  VALUES
    (p_user_id, v_action_type, v_admin.id, v_admin.email, v_admin.role, p_report_id, v_restriction,
     v_reason, v_note, v_prev, v_new,
     jsonb_strip_nulls(jsonb_build_object(
       'kind', p_kind,
       'ends_at', p_ends_at,
       'superseded', CASE WHEN cardinality(v_superseded) > 0 THEN to_jsonb(v_superseded) END,
       'hide_listings', CASE WHEN p_hide_listings THEN true END)),
     p_request_id)
  RETURNING id INTO v_action;

  -- Hiding the account's OPEN listings. A banned seller's live offers are dead
  -- ends — anyone who applies or messages is talking to someone who can no
  -- longer answer. Only `open` listings: one with a provider selected or money
  -- held is a job in flight, and hiding it would hide the job from the
  -- innocent counterparty too. Each hidden listing is its own ledger row, so
  -- each can be restored individually.
  IF p_hide_listings THEN
    FOR r IN
      SELECT p.id, p.title, p.type, p.status
        FROM public.posts p
       WHERE p.author_user_id = p_user_id
         AND p.archived_at IS NULL
         AND p.status = 'open'
       FOR UPDATE
    LOOP
      UPDATE public.posts SET archived_at = now(), archived_by = 'moderation' WHERE id = r.id;

      INSERT INTO public.moderation_actions
        (target_user_id, action_type, admin_id, admin_email, admin_role, report_id, content_type,
         content_id, reason, previous_state, new_state, metadata, request_id)
      VALUES
        (p_user_id, 'content_removed', v_admin.id, v_admin.email, v_admin.role, p_report_id, 'post',
         r.id::text, 'Hidden together with the account ' || p_kind || '.',
         jsonb_build_object('visible', true), jsonb_build_object('visible', false),
         jsonb_build_object('cascade_of', v_action,
                            'snapshot', jsonb_build_object('title', r.title, 'type', r.type, 'status', r.status)),
         p_request_id);

      v_hidden := v_hidden || r.id;
    END LOOP;
  END IF;

  -- Close the report that prompted this, when asked to, in the same breath.
  IF p_report_id IS NOT NULL AND p_resolve_report
     AND v_report.status IN ('new', 'under_review', 'action_required') THEN
    UPDATE public.user_reports
       SET status = 'resolved', resolution = 'action_taken', resolution_reason = v_reason,
           resolved_at = now(), resolved_by = p_admin_id,
           assigned_admin_id = coalesce(assigned_admin_id, p_admin_id),
           assigned_at = coalesce(assigned_at, now())
     WHERE id = p_report_id;

    INSERT INTO public.moderation_actions
      (target_user_id, action_type, admin_id, admin_email, admin_role, report_id, reason,
       previous_state, new_state, metadata, request_id)
    VALUES
      (p_user_id, 'report_resolved', v_admin.id, v_admin.email, v_admin.role, p_report_id,
       'Resolved with ' || replace(v_action_type, '_', ' ') || '.',
       jsonb_build_object('status', v_report.status),
       jsonb_build_object('status', 'resolved', 'resolution', 'action_taken'),
       jsonb_build_object('via_action', v_action), p_request_id);

    v_resolved := true;
  END IF;

  RETURN jsonb_build_object(
    'action_id',       v_action,
    'action_type',     v_action_type,
    'restriction_id',  v_restriction,
    'superseded',      to_jsonb(v_superseded),
    'hidden_posts',    to_jsonb(v_hidden),
    'report_resolved', v_resolved,
    'state',           v_new);
END;
$$;

-- =============================================================================
-- moderation_lift_restriction
-- =============================================================================
CREATE OR REPLACE FUNCTION public.moderation_lift_restriction(
  p_admin_id       uuid,
  p_restriction_id uuid,
  p_reason         text,
  p_internal_note  text DEFAULT NULL,
  p_request_id     text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin  public.admin_users%ROWTYPE;
  v_r      public.account_restrictions%ROWTYPE;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_note   text := nullif(btrim(coalesce(p_internal_note, '')), '');
  v_prev   jsonb;
  v_new    jsonb;
  v_action uuid;
BEGIN
  PERFORM public.moderation_assert_trusted();
  v_admin := public.moderation_require_admin(p_admin_id);

  IF char_length(v_reason) < 10 OR char_length(v_reason) > 1000 THEN
    RAISE EXCEPTION 'HELP24_MODERATION_INVALID: a reason of 10 to 1000 characters is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_r FROM public.account_restrictions WHERE id = p_restriction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_MODERATION_NOT_FOUND: restriction not found' USING ERRCODE = '22023';
  END IF;
  IF v_r.lifted_at IS NOT NULL THEN
    RAISE EXCEPTION 'HELP24_MODERATION_CONFLICT: this restriction was already lifted' USING ERRCODE = '23505';
  END IF;
  IF v_r.ends_at IS NOT NULL AND v_r.ends_at <= now() THEN
    RAISE EXCEPTION 'HELP24_MODERATION_CONFLICT: this restriction has already ended' USING ERRCODE = '23505';
  END IF;

  v_prev := public.moderation_state_json(v_r.user_id);
  PERFORM set_config('help24.moderation_write', 'on', true);

  UPDATE public.account_restrictions
     SET lifted_at = now(), lifted_by = p_admin_id, lift_reason = v_reason
   WHERE id = p_restriction_id;

  IF v_r.kind = 'ban' AND NOT ('ban' = ANY (public.moderation_active_kinds(v_r.user_id))) THEN
    UPDATE public.users SET is_banned = false WHERE id = v_r.user_id AND is_banned IS TRUE;
  END IF;

  v_new := public.moderation_state_json(v_r.user_id);

  INSERT INTO public.moderation_actions
    (target_user_id, action_type, admin_id, admin_email, admin_role, report_id, restriction_id,
     reason, internal_note, previous_state, new_state, metadata, request_id)
  VALUES
    (v_r.user_id, 'restriction_lifted', v_admin.id, v_admin.email, v_admin.role, v_r.report_id, v_r.id,
     v_reason, v_note, v_prev, v_new, jsonb_build_object('kind', v_r.kind), p_request_id)
  RETURNING id INTO v_action;

  RETURN jsonb_build_object('action_id', v_action, 'user_id', v_r.user_id, 'kind', v_r.kind, 'state', v_new);
END;
$$;

-- =============================================================================
-- moderation_update_report — triage
-- =============================================================================
-- Status moves among the OPEN states (new → under_review ⇄ action_required).
-- Moving a closed report back to under_review/action_required is a REOPEN and
-- is recorded as one. Closing goes through moderation_resolve_report.
CREATE OR REPLACE FUNCTION public.moderation_update_report(
  p_admin_id   uuid,
  p_report_id  uuid,
  p_status     text    DEFAULT NULL,
  p_severity   text    DEFAULT NULL,
  p_assign_to  uuid    DEFAULT NULL,
  p_unassign   boolean DEFAULT false,
  p_reason     text    DEFAULT NULL,
  p_request_id text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin     public.admin_users%ROWTYPE;
  v_assignee  public.admin_users%ROWTYPE;
  v_rep       public.user_reports%ROWTYPE;
  v_status    text;
  v_severity  text;
  v_assigned  uuid;
  v_reopen    boolean := false;
  v_changes   text[] := '{}';
  v_action    uuid;
  v_reason    text;
BEGIN
  PERFORM public.moderation_assert_trusted();
  v_admin := public.moderation_require_admin(p_admin_id);

  SELECT * INTO v_rep FROM public.user_reports WHERE id = p_report_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_MODERATION_NOT_FOUND: report not found' USING ERRCODE = '22023';
  END IF;

  v_status   := v_rep.status;
  v_severity := v_rep.severity;
  v_assigned := v_rep.assigned_admin_id;

  IF p_status IS NOT NULL AND p_status <> v_rep.status THEN
    IF p_status NOT IN ('under_review', 'action_required') THEN
      RAISE EXCEPTION 'HELP24_MODERATION_INVALID: status % cannot be set here — close a report with moderation_resolve_report', p_status
        USING ERRCODE = '22023';
    END IF;
    v_reopen := v_rep.status IN ('resolved', 'dismissed');
    v_status := p_status;
    v_changes := v_changes || format('status %s → %s', v_rep.status, p_status);
  END IF;

  IF p_severity IS NOT NULL AND p_severity <> v_rep.severity THEN
    IF p_severity NOT IN ('low', 'medium', 'high', 'critical') THEN
      RAISE EXCEPTION 'HELP24_MODERATION_INVALID: unknown severity %', p_severity USING ERRCODE = '22023';
    END IF;
    v_severity := p_severity;
    v_changes := v_changes || format('severity %s → %s', v_rep.severity, p_severity);
  END IF;

  IF p_unassign AND v_rep.assigned_admin_id IS NOT NULL THEN
    v_assigned := NULL;
    v_changes := v_changes || 'unassigned'::text;
  ELSIF p_assign_to IS NOT NULL AND p_assign_to IS DISTINCT FROM v_rep.assigned_admin_id THEN
    v_assignee := public.moderation_require_admin(p_assign_to);
    v_assigned := v_assignee.id;
    v_changes := v_changes || format('assigned to %s', v_assignee.email);
  END IF;

  IF cardinality(v_changes) = 0 THEN
    RAISE EXCEPTION 'HELP24_MODERATION_NO_CHANGE: nothing to update' USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('help24.moderation_write', 'on', true);

  UPDATE public.user_reports
     SET status            = v_status,
         severity          = v_severity,
         assigned_admin_id = v_assigned,
         assigned_at       = CASE WHEN v_assigned IS NULL THEN NULL
                                  WHEN v_assigned IS DISTINCT FROM v_rep.assigned_admin_id THEN now()
                                  ELSE v_rep.assigned_at END,
         resolved_at       = CASE WHEN v_reopen THEN NULL ELSE resolved_at END,
         resolved_by       = CASE WHEN v_reopen THEN NULL ELSE resolved_by END,
         resolution        = CASE WHEN v_reopen THEN NULL ELSE resolution END,
         resolution_reason = CASE WHEN v_reopen THEN NULL ELSE resolution_reason END
   WHERE id = p_report_id;

  v_reason := coalesce(nullif(btrim(coalesce(p_reason, '')), ''),
                       initcap(replace(array_to_string(v_changes, '; '), '_', ' ')) || '.');

  INSERT INTO public.moderation_actions
    (target_user_id, action_type, admin_id, admin_email, admin_role, report_id, reason,
     previous_state, new_state, request_id)
  VALUES
    (v_rep.reported_user_id, CASE WHEN v_reopen THEN 'report_reopened' ELSE 'report_triaged' END,
     v_admin.id, v_admin.email, v_admin.role, p_report_id, left(v_reason, 2000),
     jsonb_strip_nulls(jsonb_build_object('status', v_rep.status, 'severity', v_rep.severity,
                                          'assigned_admin_id', v_rep.assigned_admin_id,
                                          'resolution', v_rep.resolution)),
     jsonb_strip_nulls(jsonb_build_object('status', v_status, 'severity', v_severity,
                                          'assigned_admin_id', v_assigned)),
     p_request_id)
  RETURNING id INTO v_action;

  RETURN jsonb_build_object('action_id', v_action, 'status', v_status, 'severity', v_severity,
                            'assigned_admin_id', v_assigned, 'reopened', v_reopen);
END;
$$;

-- =============================================================================
-- moderation_resolve_report — close a report
-- =============================================================================
-- `dismissed`  the report is not upheld (no violation, not enough evidence).
-- `resolved`   it was dealt with. The resolution is DERIVED, not claimed:
--              'action_taken' only if a sanction or a content action is
--              actually linked to this report in the ledger, else 'no_action'.
CREATE OR REPLACE FUNCTION public.moderation_resolve_report(
  p_admin_id      uuid,
  p_report_id     uuid,
  p_outcome       text,
  p_reason        text,
  p_internal_note text DEFAULT NULL,
  p_request_id    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin      public.admin_users%ROWTYPE;
  v_rep        public.user_reports%ROWTYPE;
  v_reason     text := btrim(coalesce(p_reason, ''));
  v_note       text := nullif(btrim(coalesce(p_internal_note, '')), '');
  v_resolution text;
  v_status     text;
  v_action     uuid;
BEGIN
  PERFORM public.moderation_assert_trusted();
  v_admin := public.moderation_require_admin(p_admin_id);

  IF p_outcome IS NULL OR p_outcome NOT IN ('resolved', 'dismissed') THEN
    RAISE EXCEPTION 'HELP24_MODERATION_INVALID: outcome must be resolved or dismissed' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_reason) < 5 OR char_length(v_reason) > 1000 THEN
    RAISE EXCEPTION 'HELP24_MODERATION_INVALID: a reason of 5 to 1000 characters is required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_rep FROM public.user_reports WHERE id = p_report_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HELP24_MODERATION_NOT_FOUND: report not found' USING ERRCODE = '22023';
  END IF;
  IF v_rep.status IN ('resolved', 'dismissed') THEN
    RAISE EXCEPTION 'HELP24_MODERATION_CONFLICT: this report is already closed' USING ERRCODE = '23505';
  END IF;

  IF p_outcome = 'dismissed' THEN
    v_status := 'dismissed';
    v_resolution := 'dismissed';
  ELSE
    v_status := 'resolved';
    v_resolution := CASE WHEN EXISTS (
        SELECT 1 FROM public.moderation_actions a
         WHERE a.report_id = p_report_id
           AND a.action_type IN ('warning_issued', 'suspension_applied', 'ban_applied',
                                 'messaging_restricted', 'marketplace_restricted', 'content_removed'))
      THEN 'action_taken' ELSE 'no_action' END;
  END IF;

  PERFORM set_config('help24.moderation_write', 'on', true);

  UPDATE public.user_reports
     SET status = v_status, resolution = v_resolution, resolution_reason = v_reason,
         resolved_at = now(), resolved_by = p_admin_id,
         assigned_admin_id = coalesce(assigned_admin_id, p_admin_id),
         assigned_at = coalesce(assigned_at, now())
   WHERE id = p_report_id;

  INSERT INTO public.moderation_actions
    (target_user_id, action_type, admin_id, admin_email, admin_role, report_id, reason,
     internal_note, previous_state, new_state, request_id)
  VALUES
    (v_rep.reported_user_id,
     CASE WHEN v_status = 'dismissed' THEN 'report_dismissed' ELSE 'report_resolved' END,
     v_admin.id, v_admin.email, v_admin.role, p_report_id, v_reason, v_note,
     jsonb_build_object('status', v_rep.status),
     jsonb_build_object('status', v_status, 'resolution', v_resolution),
     p_request_id)
  RETURNING id INTO v_action;

  RETURN jsonb_build_object('action_id', v_action, 'status', v_status, 'resolution', v_resolution);
END;
$$;

-- =============================================================================
-- moderation_add_note — admin-only context, on a report or an account
-- =============================================================================
CREATE OR REPLACE FUNCTION public.moderation_add_note(
  p_admin_id   uuid,
  p_note       text,
  p_user_id    text DEFAULT NULL,
  p_report_id  uuid DEFAULT NULL,
  p_request_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin  public.admin_users%ROWTYPE;
  v_note   text := btrim(coalesce(p_note, ''));
  v_target text;
  v_action uuid;
BEGIN
  PERFORM public.moderation_assert_trusted();
  v_admin := public.moderation_require_admin(p_admin_id);

  IF char_length(v_note) < 1 OR char_length(v_note) > 4000 THEN
    RAISE EXCEPTION 'HELP24_MODERATION_INVALID: a note of 1 to 4000 characters is required' USING ERRCODE = '22023';
  END IF;

  IF p_report_id IS NOT NULL THEN
    SELECT reported_user_id INTO v_target FROM public.user_reports WHERE id = p_report_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'HELP24_MODERATION_NOT_FOUND: report not found' USING ERRCODE = '22023';
    END IF;
    IF p_user_id IS NOT NULL AND p_user_id <> v_target THEN
      RAISE EXCEPTION 'HELP24_MODERATION_INVALID: that report is not about this account' USING ERRCODE = '22023';
    END IF;
  ELSE
    SELECT id INTO v_target FROM public.users WHERE id = p_user_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'HELP24_MODERATION_NOT_FOUND: account not found' USING ERRCODE = '22023';
    END IF;
  END IF;

  INSERT INTO public.moderation_actions
    (target_user_id, action_type, admin_id, admin_email, admin_role, report_id, reason,
     internal_note, request_id)
  VALUES
    (v_target, 'note_added', v_admin.id, v_admin.email, v_admin.role, p_report_id,
     'Internal note', v_note, p_request_id)
  RETURNING id INTO v_action;

  RETURN jsonb_build_object('action_id', v_action, 'user_id', v_target);
END;
$$;

-- =============================================================================
-- moderation_set_content_state — hide or restore one listing or message
-- =============================================================================
-- HIDING, NEVER DELETING. A listing is hidden the way its owner archives one
-- (`archived_at`), which every feed, search and list already excludes — so it
-- disappears everywhere at once without touching the ranking engine. It is
-- marked `archived_by = 'moderation'`, which migration 116 uses to stop the
-- owner restoring or deleting it. A message is hidden the way "delete for
-- everyone" hides one; its content is kept, because it is evidence.
CREATE OR REPLACE FUNCTION public.moderation_set_content_state(
  p_admin_id      uuid,
  p_content_type  text,
  p_content_id    text,
  p_action        text,
  p_reason        text,
  p_internal_note text DEFAULT NULL,
  p_report_id     uuid DEFAULT NULL,
  p_request_id    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_uuid     CONSTANT text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  v_admin    public.admin_users%ROWTYPE;
  v_reason   text := btrim(coalesce(p_reason, ''));
  v_note     text := nullif(btrim(coalesce(p_internal_note, '')), '');
  v_post     public.posts%ROWTYPE;
  v_msg      public.chat_messages%ROWTYPE;
  v_owner    text;
  v_snapshot jsonb;
  v_report   public.user_reports%ROWTYPE;
  v_action   uuid;
BEGIN
  PERFORM public.moderation_assert_trusted();
  v_admin := public.moderation_require_admin(p_admin_id);

  IF p_action IS NULL OR p_action NOT IN ('remove', 'restore') THEN
    RAISE EXCEPTION 'HELP24_MODERATION_INVALID: action must be remove or restore' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_reason) < 10 OR char_length(v_reason) > 1000 THEN
    RAISE EXCEPTION 'HELP24_MODERATION_INVALID: a reason of 10 to 1000 characters is required' USING ERRCODE = '22023';
  END IF;
  IF p_content_id IS NULL OR p_content_id !~* c_uuid THEN
    RAISE EXCEPTION 'HELP24_MODERATION_INVALID: malformed content id' USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('help24.moderation_write', 'on', true);

  IF p_content_type = 'post' THEN
    SELECT * INTO v_post FROM public.posts WHERE id = p_content_id::uuid FOR UPDATE;
    IF NOT FOUND OR v_post.author_user_id IS NULL THEN
      RAISE EXCEPTION 'HELP24_MODERATION_NOT_FOUND: listing not found' USING ERRCODE = '22023';
    END IF;
    v_owner := v_post.author_user_id;
    v_snapshot := jsonb_build_object('title', v_post.title, 'type', v_post.type, 'status', v_post.status,
                                     'description', left(coalesce(v_post.description, ''), 1000));

    IF p_action = 'remove' THEN
      IF v_post.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'HELP24_MODERATION_CONFLICT: this listing is already hidden' USING ERRCODE = '23505';
      END IF;
      -- Only a listing still open to applicants. Once a provider is selected the
      -- listing IS the job: the app drops archived posts from its owner's lists,
      -- so hiding it would strand the job, its payment and any dispute. Those
      -- are handled in Disputes, or by acting on the account.
      IF v_post.status IS DISTINCT FROM 'open' THEN
        RAISE EXCEPTION 'HELP24_MODERATION_CONFLICT: only a listing still open to applicants can be hidden — this one is %', v_post.status
          USING ERRCODE = '23505';
      END IF;
      UPDATE public.posts SET archived_at = now(), archived_by = 'moderation' WHERE id = v_post.id;
    ELSE
      IF v_post.archived_by IS DISTINCT FROM 'moderation' THEN
        RAISE EXCEPTION 'HELP24_MODERATION_CONFLICT: this listing was not hidden by moderation' USING ERRCODE = '23505';
      END IF;
      UPDATE public.posts SET archived_at = NULL, archived_by = NULL WHERE id = v_post.id;
    END IF;

  ELSIF p_content_type = 'message' THEN
    SELECT * INTO v_msg FROM public.chat_messages WHERE id = p_content_id::uuid FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'HELP24_MODERATION_NOT_FOUND: message not found' USING ERRCODE = '22023';
    END IF;
    v_owner := v_msg.sender_id;
    v_snapshot := jsonb_build_object('content', left(coalesce(v_msg.content, ''), 1000), 'type', v_msg.type,
                                     'sent_at', v_msg.created_at, 'chat_id', v_msg.chat_id);

    IF p_action = 'remove' THEN
      IF v_msg.deleted_for_everyone THEN
        RAISE EXCEPTION 'HELP24_MODERATION_CONFLICT: this message is already hidden' USING ERRCODE = '23505';
      END IF;
      UPDATE public.chat_messages SET deleted_for_everyone = true, deleted_at = now() WHERE id = v_msg.id;
    ELSE
      -- Only what moderation hid may moderation restore: a message its sender
      -- deleted stays deleted. The ledger is the record of who hid it.
      IF NOT v_msg.deleted_for_everyone OR NOT EXISTS (
          SELECT 1 FROM (
            SELECT a.action_type FROM public.moderation_actions a
             WHERE a.content_type = 'message' AND a.content_id = p_content_id
             ORDER BY a.created_at DESC, a.chain_seq DESC LIMIT 1) last
           WHERE last.action_type = 'content_removed') THEN
        RAISE EXCEPTION 'HELP24_MODERATION_CONFLICT: this message was not hidden by moderation' USING ERRCODE = '23505';
      END IF;
      UPDATE public.chat_messages SET deleted_for_everyone = false, deleted_at = NULL WHERE id = v_msg.id;
    END IF;

  ELSE
    RAISE EXCEPTION 'HELP24_MODERATION_INVALID: content type must be post or message' USING ERRCODE = '22023';
  END IF;

  IF p_report_id IS NOT NULL THEN
    SELECT * INTO v_report FROM public.user_reports WHERE id = p_report_id;
    IF NOT FOUND OR v_report.reported_user_id <> v_owner THEN
      RAISE EXCEPTION 'HELP24_MODERATION_INVALID: that report is not about this content''s owner' USING ERRCODE = '22023';
    END IF;
  END IF;

  INSERT INTO public.moderation_actions
    (target_user_id, action_type, admin_id, admin_email, admin_role, report_id, content_type,
     content_id, reason, internal_note, previous_state, new_state, metadata, request_id)
  VALUES
    (v_owner, CASE WHEN p_action = 'remove' THEN 'content_removed' ELSE 'content_restored' END,
     v_admin.id, v_admin.email, v_admin.role, p_report_id, p_content_type, p_content_id,
     v_reason, v_note,
     jsonb_build_object('visible', p_action <> 'remove'),
     jsonb_build_object('visible', p_action = 'restore'),
     jsonb_build_object('snapshot', v_snapshot),
     p_request_id)
  RETURNING id INTO v_action;

  RETURN jsonb_build_object('action_id', v_action, 'owner_user_id', v_owner,
                            'content_type', p_content_type, 'content_id', p_content_id,
                            'visible', p_action = 'restore');
END;
$$;

-- ── Access: the backend only ─────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.moderation_assert_trusted()                FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_require_admin(uuid)             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_apply_sanction(uuid, text, text, text, text, timestamptz, uuid, boolean, boolean, text)
                                                                         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_lift_restriction(uuid, uuid, text, text, text)
                                                                         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_update_report(uuid, uuid, text, text, uuid, boolean, text, text)
                                                                         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_resolve_report(uuid, uuid, text, text, text, text)
                                                                         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_add_note(uuid, text, text, uuid, text)
                                                                         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_set_content_state(uuid, text, text, text, text, text, uuid, text)
                                                                         FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.moderation_apply_sanction(uuid, text, text, text, text, timestamptz, uuid, boolean, boolean, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.moderation_lift_restriction(uuid, uuid, text, text, text)                                         TO service_role;
GRANT EXECUTE ON FUNCTION public.moderation_update_report(uuid, uuid, text, text, uuid, boolean, text, text)                        TO service_role;
GRANT EXECUTE ON FUNCTION public.moderation_resolve_report(uuid, uuid, text, text, text, text)                                      TO service_role;
GRANT EXECUTE ON FUNCTION public.moderation_add_note(uuid, text, text, uuid, text)                                                 TO service_role;
GRANT EXECUTE ON FUNCTION public.moderation_set_content_state(uuid, text, text, text, text, text, uuid, text)                       TO service_role;

COMMIT;
