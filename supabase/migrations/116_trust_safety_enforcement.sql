-- =============================================================================
-- 116 — Trust & Safety, part 3 of 3: restrictions take effect in the database
-- =============================================================================
-- NOT APPLIED. Requires 114. THIS is the migration that changes behaviour for
-- users — for RESTRICTED users only (0 on 2026-09-27). Everyone else's inserts
-- pass one indexed lookup and continue exactly as before.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHY ENFORCEMENT HAS TO LIVE HERE, AND NOT ONLY IN THE BACKEND
-- ─────────────────────────────────────────────────────────────────────────────
-- The app writes listings, applications, conversations and messages DIRECTLY
-- to Supabase (post_service.dart, application_service.dart,
-- chat_service_supabase.dart). None of those writes passes through NestJS, so a
-- backend-only check would stop the actions that go through the backend
-- (hiring, paying, completing, reviewing, promoting — see ModerationGuard) and
-- leave a banned account free to keep posting and messaging. These triggers
-- close that door; the backend guard closes the other one; both read the same
-- capability map, moderation_denial() (migration 114).
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHO IS CHECKED
-- ─────────────────────────────────────────────────────────────────────────────
-- BOTH the caller's JWT identity AND the row's acting-person column. The second
-- matters because `posts` and `applications` still accept inserts from `anon`
-- with a client-chosen author id (policies `posts_insert` / `applications_insert`
-- are WITH CHECK (true)). A restricted person inserting as themselves is
-- refused whichever way they arrive. Inserting under SOMEONE ELSE's id is
-- impersonation — a pre-existing gap these policies leave open, reported
-- separately and not closed here.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- IF ENFORCEMENT ITSELF FAILS
-- ─────────────────────────────────────────────────────────────────────────────
-- It fails OPEN, with a WARNING in the Postgres log. A bug here must not become
-- "nobody in Kenya can post a listing"; the same rule the platform already
-- applies to kill switches and to derived counters (fn_touch_post_engagement).
-- The deliberate refusal (SQLSTATE 42501, message HELP24_ACCOUNT_RESTRICTED) is
-- re-raised; anything else is logged and let through.
--
-- The app recognises HELP24_ACCOUNT_RESTRICTED (ErrorMapper) and shows the
-- account-status explanation instead of a generic failure.
--
-- Rollback (restores pre-116 behaviour exactly):
--   DROP TRIGGER IF EXISTS trg_moderation_enforce_posts          ON public.posts;
--   DROP TRIGGER IF EXISTS trg_moderation_enforce_post_images    ON public.post_images;
--   DROP TRIGGER IF EXISTS trg_moderation_enforce_applications   ON public.applications;
--   DROP TRIGGER IF EXISTS trg_moderation_enforce_chats          ON public.chats;
--   DROP TRIGGER IF EXISTS trg_moderation_enforce_chat_preview   ON public.chats;
--   DROP TRIGGER IF EXISTS trg_moderation_enforce_chat_messages  ON public.chat_messages;
--   DROP TRIGGER IF EXISTS trg_moderation_enforce_message_edits  ON public.chat_messages;
--   DROP TRIGGER IF EXISTS trg_posts_moderation_guard            ON public.posts;
--   DROP TRIGGER IF EXISTS trg_chat_messages_undelete_guard      ON public.chat_messages;
--   DROP FUNCTION IF EXISTS public.fn_moderation_enforce(), public.fn_posts_moderation_guard(),
--     public.fn_chat_messages_undelete_guard();
-- =============================================================================

BEGIN;

-- TG_ARGV[0]  the capability (see moderation_capabilities()).
-- TG_ARGV[1]  the row column naming the acting person; '' to check the JWT
--             only; '@post_author' to resolve it through post_id.
CREATE OR REPLACE FUNCTION public.fn_moderation_enforce()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_capability text := TG_ARGV[0];
  v_column     text := coalesce(TG_ARGV[1], '');
  v_jwt_uid    text;
  v_row_uid    text;
  v_who        text;
  v_denial     text;
BEGIN
  -- The backend enforces its own routes (ModerationGuard) and performs writes
  -- on people's behalf that must not be refused here — the chat it opens when a
  -- provider is selected, for one. Owner connections are migrations and ops.
  IF public.moderation_caller_is_trusted() THEN
    RETURN NEW;
  END IF;

  v_jwt_uid := nullif(btrim(coalesce(
    coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'user_id', '')), '');

  IF v_column = '@post_author' THEN
    SELECT p.author_user_id INTO v_row_uid FROM public.posts p WHERE p.id = NEW.post_id;
  ELSIF v_column <> '' THEN
    v_row_uid := nullif(btrim(coalesce(to_jsonb(NEW) ->> v_column, '')), '');
  END IF;

  FOREACH v_who IN ARRAY ARRAY[v_jwt_uid, v_row_uid] LOOP
    CONTINUE WHEN v_who IS NULL;
    v_denial := public.moderation_denial(v_who, v_capability);
    IF v_denial IS NOT NULL THEN
      RAISE EXCEPTION 'HELP24_ACCOUNT_RESTRICTED: %', v_denial
        USING ERRCODE = '42501',
              DETAIL  = v_capability,
              HINT    = 'This account is restricted. Open Help24 to see why and how to get help.';
    END IF;
  END LOOP;

  RETURN NEW;
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE;
  WHEN OTHERS THEN
    RAISE WARNING 'HELP24 moderation enforcement skipped on % % (%): %',
      TG_TABLE_NAME, TG_OP, SQLSTATE, SQLERRM;
    RETURN NEW;
END;
$$;

-- Listings: creating AND editing. A suspended seller rewriting a live offer to
-- point buyers at a WhatsApp number is exactly the thing being prevented.
DROP TRIGGER IF EXISTS trg_moderation_enforce_posts ON public.posts;
CREATE TRIGGER trg_moderation_enforce_posts
  BEFORE INSERT OR UPDATE ON public.posts
  FOR EACH ROW EXECUTE FUNCTION public.fn_moderation_enforce('post', 'author_user_id');

-- Photos are listing content too. post_images carries no author, so the
-- listing's author is the one checked.
DROP TRIGGER IF EXISTS trg_moderation_enforce_post_images ON public.post_images;
CREATE TRIGGER trg_moderation_enforce_post_images
  BEFORE INSERT ON public.post_images
  FOR EACH ROW EXECUTE FUNCTION public.fn_moderation_enforce('post', '@post_author');

DROP TRIGGER IF EXISTS trg_moderation_enforce_applications ON public.applications;
CREATE TRIGGER trg_moderation_enforce_applications
  BEFORE INSERT ON public.applications
  FOR EACH ROW EXECUTE FUNCTION public.fn_moderation_enforce('apply', 'applicant_user_id');

-- Opening a conversation. A chat row names two people and not which of them
-- started it, so the caller's JWT is the one checked.
DROP TRIGGER IF EXISTS trg_moderation_enforce_chats ON public.chats;
CREATE TRIGGER trg_moderation_enforce_chats
  BEFORE INSERT ON public.chats
  FOR EACH ROW EXECUTE FUNCTION public.fn_moderation_enforce('message', '');

-- The conversation-list preview is text the other person reads; writing it is
-- messaging by another route. (Read receipts and typing touch other columns
-- and are not affected.)
DROP TRIGGER IF EXISTS trg_moderation_enforce_chat_preview ON public.chats;
CREATE TRIGGER trg_moderation_enforce_chat_preview
  BEFORE UPDATE OF last_message ON public.chats
  FOR EACH ROW EXECUTE FUNCTION public.fn_moderation_enforce('message', '');

DROP TRIGGER IF EXISTS trg_moderation_enforce_chat_messages ON public.chat_messages;
CREATE TRIGGER trg_moderation_enforce_chat_messages
  BEFORE INSERT ON public.chat_messages
  FOR EACH ROW EXECUTE FUNCTION public.fn_moderation_enforce('message', 'sender_id');

-- Rewriting the text of a sent message is sending text.
DROP TRIGGER IF EXISTS trg_moderation_enforce_message_edits ON public.chat_messages;
CREATE TRIGGER trg_moderation_enforce_message_edits
  BEFORE UPDATE OF content ON public.chat_messages
  FOR EACH ROW EXECUTE FUNCTION public.fn_moderation_enforce('message', 'sender_id');

-- ── Hidden content stays hidden ──────────────────────────────────────────────
-- A listing hidden by moderation (archived_by = 'moderation', set only by
-- moderation_set_content_state / moderation_apply_sanction) cannot be edited,
-- un-archived or deleted by its owner — the last would destroy the evidence
-- the decision rests on. Nor can anyone but moderation mark a listing that way.
CREATE OR REPLACE FUNCTION public.fn_posts_moderation_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.moderation_caller_is_trusted() THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;

  IF TG_OP IN ('UPDATE', 'DELETE') AND OLD.archived_by = 'moderation' THEN
    RAISE EXCEPTION 'HELP24_CONTENT_MODERATED: this listing was hidden by Help24 and cannot be changed'
      USING ERRCODE = '42501';
  END IF;

  IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.archived_by = 'moderation' THEN
    RAISE EXCEPTION 'HELP24_CONTENT_MODERATED: only Help24 can mark a listing as moderated'
      USING ERRCODE = '42501';
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

DROP TRIGGER IF EXISTS trg_posts_moderation_guard ON public.posts;
CREATE TRIGGER trg_posts_moderation_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.posts
  FOR EACH ROW EXECUTE FUNCTION public.fn_posts_moderation_guard();

-- A message deleted for everyone — by its sender or by moderation — is not
-- brought back by a client. No app feature restores one; moderation can, and
-- does so through moderation_set_content_state with a ledger row.
CREATE OR REPLACE FUNCTION public.fn_chat_messages_undelete_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.moderation_caller_is_trusted() THEN
    RETURN NEW;
  END IF;
  IF OLD.deleted_for_everyone AND NOT coalesce(NEW.deleted_for_everyone, false) THEN
    RAISE EXCEPTION 'HELP24_CONTENT_MODERATED: a deleted message cannot be restored'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_chat_messages_undelete_guard ON public.chat_messages;
CREATE TRIGGER trg_chat_messages_undelete_guard
  BEFORE UPDATE OF deleted_for_everyone ON public.chat_messages
  FOR EACH ROW EXECUTE FUNCTION public.fn_chat_messages_undelete_guard();

REVOKE ALL ON FUNCTION public.fn_moderation_enforce()           FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_posts_moderation_guard()       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_chat_messages_undelete_guard() FROM PUBLIC, anon, authenticated;

COMMIT;
