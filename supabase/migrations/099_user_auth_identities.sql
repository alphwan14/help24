-- 099 — One person, one identity: separate the dashboard CREDENTIAL from the
-- marketplace IDENTITY.
--
-- WHY THIS EXISTS (confirmed live, 2026-08-06):
-- `on_auth_user_created` on auth.users calls handle_new_auth_user(), which
-- INSERTs a public.users row keyed by the Supabase UUID. So creating an admin
-- dashboard login also creates a *person* in the marketplace. Live proof:
--   3 of 17 public.users rows are UUID-shaped dashboard mirrors
--   (christianobuna3@, zurinsojars@ [role=admin], karenbrina98@).
--   All three own 0 posts, 0 applications, 0 messages, 0 chats, 0 reviews.
-- Meanwhile 100% of real marketplace data hangs off Firebase UIDs, and the
-- token bridge mints `user_id = <Firebase UID>`. Firebase UID is canonical.
--
-- A second live defect the same trigger causes: it inserts
-- `ON CONFLICT (id) DO NOTHING`, but public.users carries `users_email_unique`.
-- Inviting an EXISTING member to the dashboard therefore raises a unique
-- violation that rolls back the whole auth.users INSERT — the invite fails with
-- a raw database error. This is not hypothetical: alphwan14@ and alphlincoln18@
-- both hold a Firebase public.users row AND an auth.users row, and only avoided
-- it because their auth rows predate the trigger.
--
-- WHAT THIS MIGRATION DOES *NOT* DO:
-- No row is deleted. No two rows are merged. The three mirror rows stay exactly
-- as they are — they own nothing, so they are harmless, and destroying them is
-- not reversible. Cross-shape links (one email holding both a Firebase identity
-- and an unmatched auth.users row) are NOT created automatically; they are
-- surfaced in `identity.auth_link_candidates` for a human to approve one at a
-- time. See docs/runbooks/admin-onboarding-and-identity-linking.md.
--
-- ROLLBACK (in this order):
--   CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
--     FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();
--   DROP SCHEMA IF EXISTS identity CASCADE;
--   DROP TABLE IF EXISTS public.user_auth_identities;
-- handle_new_auth_user() itself is deliberately NOT dropped, so restoring the
-- old behaviour is one CREATE TRIGGER statement.

-- ---------------------------------------------------------------------------
-- Step 2 — make the linkage explicit (additive; nothing reads it yet)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.user_auth_identities (
  help24_user_id text        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  provider       text        NOT NULL CHECK (provider IN ('firebase', 'supabase')),
  subject        text        NOT NULL,
  linked_at      timestamptz NOT NULL DEFAULT now(),
  -- NULL means "mechanical backfill from data that was already unambiguous".
  -- A non-NULL value names the human who approved a judgement call.
  linked_by      text,
  PRIMARY KEY (provider, subject),
  -- One credential per provider per person. A person's second Firebase sign-in
  -- method is linked onto their existing UID by Firebase, so it is still one
  -- subject — this constraint does not fight that.
  CONSTRAINT user_auth_identities_one_per_provider UNIQUE (help24_user_id, provider)
);

CREATE INDEX IF NOT EXISTS idx_user_auth_identities_user
  ON public.user_auth_identities (help24_user_id);

COMMENT ON TABLE public.user_auth_identities IS
  'Maps a login credential (Firebase UID or auth.users id) to the one Help24 identity it belongs to. A Supabase Auth account is a dashboard credential, never a person.';

-- This table decides who is an admin. It must never be readable or writable
-- with the publishable key. RLS on with zero policies = default deny for every
-- role; service_role and the owner bypass RLS. The REVOKE is belt-and-braces
-- so a future permissive policy cannot silently open it.
ALTER TABLE public.user_auth_identities ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.user_auth_identities FROM anon, authenticated;

-- Backfill A — every Firebase-keyed user is its own firebase identity.
-- Unambiguous by construction: the row's id *is* the Firebase UID.
INSERT INTO public.user_auth_identities (help24_user_id, provider, subject)
SELECT u.id, 'firebase', u.id
FROM public.users u
WHERE u.id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
ON CONFLICT DO NOTHING;

-- Backfill B — an auth.users row that already owns a same-id public.users row
-- is that row's supabase credential. Also unambiguous: same id, same row.
INSERT INTO public.user_auth_identities (help24_user_id, provider, subject)
SELECT a.id::text, 'supabase', a.id::text
FROM auth.users a
JOIN public.users u ON u.id = a.id::text
ON CONFLICT DO NOTHING;

-- Deliberately NOT backfilled: auth.users rows with no same-id public.users row
-- but an email-matching Firebase row. Those are judgement calls, listed here.
--
-- This view lives OUTSIDE `public` on purpose. It reads auth.users, so it must
-- run with definer rights — and a SECURITY DEFINER view in `public` is reachable
-- through PostgREST and is flagged ERROR by Supabase's own linter. `identity` is
-- not in the exposed schema list, so the view is unreachable with the
-- publishable key by construction rather than by grant hygiene alone.
-- (security_invoker = true was tried first and fails: service_role has no SELECT
-- on auth.users, so the dashboard could not read its own reconciliation list.)
CREATE SCHEMA IF NOT EXISTS identity;
REVOKE ALL ON SCHEMA identity FROM PUBLIC;
REVOKE ALL ON SCHEMA identity FROM anon, authenticated;
GRANT USAGE ON SCHEMA identity TO service_role;

COMMENT ON SCHEMA identity IS
  'Operator-only identity reconciliation surface. NOT in the PostgREST exposed schema list, so nothing here is reachable with the publishable key.';

CREATE OR REPLACE VIEW identity.auth_link_candidates AS
SELECT
  a.id::text        AS auth_subject,
  a.email           AS auth_email,
  u.id              AS candidate_help24_user_id,
  u.role            AS candidate_role,
  a.created_at      AS auth_created_at,
  a.last_sign_in_at AS auth_last_sign_in_at
FROM auth.users a
JOIN public.users u
  ON lower(u.email) = lower(a.email)
 AND u.id <> a.id::text
WHERE NOT EXISTS (
  SELECT 1 FROM public.user_auth_identities i
  WHERE i.provider = 'supabase' AND i.subject = a.id::text
);

COMMENT ON VIEW identity.auth_link_candidates IS
  'Supabase Auth accounts whose email matches a DIFFERENT Help24 identity. Each row is a merge decision for a human, never something to automate.';

REVOKE ALL ON identity.auth_link_candidates FROM PUBLIC, anon, authenticated;
GRANT SELECT ON identity.auth_link_candidates TO service_role;

-- ---------------------------------------------------------------------------
-- Step 1 — stop the bleeding
-- ---------------------------------------------------------------------------
-- After this, creating a dashboard login no longer creates a marketplace
-- person, and inviting an existing member no longer fails on the email unique
-- constraint. The accepted consequence: a new admin must already have a Help24
-- row (i.e. have used the app), and an operator then promotes them with the
-- existing service_role server action. That is the documented runbook.
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
