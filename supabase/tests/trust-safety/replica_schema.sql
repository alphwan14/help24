-- REPLICA OF THE LIVE SCHEMA — generated, do not edit by hand.
--
-- Extracted READ-ONLY from production (taohzhnvaitrpxcyjflq) on 2026-09-27 by
-- refresh-replica.mjs: columns, constraints, indexes, trigger functions,
-- triggers, RLS flags, policies and grants for the 21 tables the Trust & Safety
-- migrations touch, plus the Supabase role model and this project's default
-- privileges. Foreign keys to tables outside that set are omitted, and the two
-- derived-counter recompute functions are stubbed (see the prelude).
--
-- This is NOT a migration and is never applied anywhere but the local test
-- database. Regenerate it when the live schema of these tables changes.



-- ── Supabase role model ────────────────────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN NOINHERIT; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN NOINHERIT; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS; END IF;
END $$;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $f$
  SELECT coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$f$;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $f$
  SELECT nullif(auth.jwt() ->> 'sub', '')::uuid
$f$;
GRANT USAGE ON SCHEMA public, auth TO anon, authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO anon, authenticated, service_role;
-- This project's LIVE default privileges (pg_default_acl, read 2026-09-27):
-- new tables in public grant ALL to service_role and nothing to anon/authenticated.
-- New functions keep Postgres' built-in EXECUTE-to-PUBLIC default, as live.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;

-- ── Stubs for derived-counter maintenance the replicated triggers call ─────
-- Both are wrapped by their callers and are irrelevant to moderation.
CREATE OR REPLACE FUNCTION public.fn_recompute_post_engagement(p_post_id text) RETURNS void LANGUAGE sql AS $f$ SELECT $f$;
CREATE OR REPLACE FUNCTION public.fn_recompute_provider_reputation(p_provider_id text) RETURNS void LANGUAGE sql AS $f$ SELECT $f$;

-- ── Tables ──

CREATE TABLE IF NOT EXISTS public.admin_users (
  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  email text NOT NULL,
  name text NOT NULL DEFAULT ''::text,
  role text NOT NULL DEFAULT 'support_agent'::text,
  token_hash text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  last_login_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.applications (
  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  post_id uuid NOT NULL,
  applicant_name text NOT NULL DEFAULT 'Anonymous'::text,
  applicant_temp_id text NOT NULL,
  applicant_user_id text,
  message text NOT NULL,
  proposed_price numeric(12,2) NOT NULL,
  created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.categories (
  id text NOT NULL,
  name text NOT NULL,
  icon text,
  sort integer NOT NULL DEFAULT 100,
  active boolean NOT NULL DEFAULT true,
  question_schema jsonb,
  schema_version integer NOT NULL DEFAULT 1,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.chat_messages (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  chat_id uuid NOT NULL,
  sender_id text NOT NULL,
  content text NOT NULL DEFAULT ''::text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  type text NOT NULL DEFAULT 'text'::text,
  latitude double precision,
  longitude double precision,
  live_until timestamp with time zone,
  attachment_url text,
  is_read boolean DEFAULT false,
  read_at timestamp with time zone,
  status text NOT NULL DEFAULT 'sent'::text,
  seen_at timestamp with time zone,
  deleted_for_everyone boolean NOT NULL DEFAULT false,
  deleted_at timestamp with time zone,
  reply_to_id text,
  reply_to_sender text,
  reply_to_preview text
);

CREATE TABLE IF NOT EXISTS public.chats (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user1 text NOT NULL,
  user2 text NOT NULL,
  post_id uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  last_message text DEFAULT ''::text,
  typing_user_id text,
  typing_at timestamp with time zone,
  user1_unread_count integer NOT NULL DEFAULT 0,
  user2_unread_count integer NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS public.dispute_decisions (
  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  dispute_id uuid NOT NULL,
  admin_id uuid,
  decided_by_system boolean NOT NULL DEFAULT false,
  decision_type text NOT NULL,
  provider_amount integer,
  client_refund_amount integer,
  reasoning text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.disputes (
  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  post_id uuid NOT NULL,
  transaction_id uuid NOT NULL,
  job_completion_id uuid,
  raised_by_user_id text NOT NULL,
  reason text NOT NULL,
  status text NOT NULL DEFAULT 'open'::text,
  admin_notes text,
  resolved_by text,
  provider_amount integer,
  buyer_refund integer,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  resolved_at timestamp with time zone,
  priority text NOT NULL DEFAULT 'medium'::text,
  assigned_admin_id uuid,
  assigned_at timestamp with time zone,
  first_response_at timestamp with time zone,
  escalated_at timestamp with time zone,
  merged_into_dispute_id uuid,
  raised_by_role text
);

CREATE TABLE IF NOT EXISTS public.escrow (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  post_id text NOT NULL,
  amount integer NOT NULL,
  status text NOT NULL DEFAULT 'locked'::text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  transaction_id uuid,
  provider_id text,
  released_at timestamp with time zone,
  payout_destination_id uuid,
  payout_destination_snapshot jsonb
);

CREATE TABLE IF NOT EXISTS public.fcm_tokens (
  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  user_id text NOT NULL,
  token text NOT NULL,
  platform text NOT NULL DEFAULT 'android'::text,
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.job_completions (
  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  post_id uuid NOT NULL,
  transaction_id uuid NOT NULL,
  provider_user_id text NOT NULL,
  client_user_id text NOT NULL,
  status text NOT NULL DEFAULT 'pending_approval'::text,
  provider_note text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  reviewed_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  user_id text NOT NULL,
  type text NOT NULL,
  title text NOT NULL,
  body text NOT NULL,
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  read boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.post_engagement (
  post_id text NOT NULL,
  application_count integer NOT NULL DEFAULT 0,
  save_count integer NOT NULL DEFAULT 0,
  message_count integer NOT NULL DEFAULT 0,
  view_count integer NOT NULL DEFAULT 0,
  last_engagement_at timestamp with time zone,
  recomputed_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.post_images (
  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  post_id uuid NOT NULL,
  image_url text NOT NULL,
  created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.posts (
  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  title text NOT NULL,
  description text NOT NULL,
  category text NOT NULL,
  location text NOT NULL,
  urgency text NOT NULL,
  price numeric(12,2) NOT NULL DEFAULT 0,
  type text NOT NULL,
  difficulty text DEFAULT 'medium'::text,
  rating numeric(2,1) DEFAULT 4.5,
  author_name text DEFAULT 'Anonymous'::text,
  author_temp_id text NOT NULL,
  author_user_id text,
  created_at timestamp with time zone DEFAULT now(),
  pricing_type text NOT NULL DEFAULT 'task'::text,
  employment_type text,
  is_urgent boolean DEFAULT false,
  latitude double precision,
  longitude double precision,
  urgent_expires_at timestamp without time zone,
  selected_provider_id text,
  status text NOT NULL DEFAULT 'open'::text,
  archived_at timestamp with time zone,
  archived_by text,
  attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
  attributes_schema_version integer
);

CREATE TABLE IF NOT EXISTS public.provider_reputation (
  provider_id text NOT NULL,
  avg_rating double precision NOT NULL DEFAULT 0,
  bayesian_rating double precision NOT NULL DEFAULT 0,
  total_reviews integer NOT NULL DEFAULT 0,
  completed_jobs integer NOT NULL DEFAULT 0,
  disputed_jobs integer NOT NULL DEFAULT 0,
  open_disputes integer NOT NULL DEFAULT 0,
  completion_rate double precision NOT NULL DEFAULT 0,
  dispute_rate double precision NOT NULL DEFAULT 0,
  repeat_clients integer NOT NULL DEFAULT 0,
  tier text NOT NULL DEFAULT 'new_provider'::text,
  last_active_at timestamp with time zone,
  recomputed_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.reviews (
  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  post_id uuid NOT NULL,
  client_id text NOT NULL,
  provider_id text NOT NULL,
  rating smallint NOT NULL,
  comment text,
  status text NOT NULL DEFAULT 'visible'::text,
  from_disputed_job boolean NOT NULL DEFAULT false,
  provider_reply text,
  provider_reply_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  edited_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.saved_items (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id text NOT NULL,
  item_type text NOT NULL,
  item_id text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.settlements (
  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  transaction_id uuid NOT NULL,
  escrow_id uuid,
  post_id text NOT NULL,
  direction text NOT NULL,
  rail text NOT NULL,
  amount integer NOT NULL,
  beneficiary_user_id text,
  status text NOT NULL,
  conversation_id text,
  originator_conversation_id text,
  mpesa_receipt text,
  failure_reason text,
  attempts integer NOT NULL DEFAULT 0,
  last_attempt_at timestamp with time zone,
  environment text NOT NULL,
  reason_ref_type text NOT NULL,
  reason_ref_id text,
  backfill_unverified boolean NOT NULL DEFAULT false,
  created_by text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  settled_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.transactions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  phone text NOT NULL,
  amount integer NOT NULL,
  fee integer NOT NULL DEFAULT 0,
  total_paid integer NOT NULL,
  status text NOT NULL DEFAULT 'pending'::text,
  mpesa_receipt text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  buyer_user_id text,
  checkout_request_id text,
  post_id uuid NOT NULL,
  conversation_id text,
  failure_reason text,
  originator_conversation_id text,
  payout_destination_id uuid
);

CREATE TABLE IF NOT EXISTS public.user_auth_identities (
  help24_user_id text NOT NULL,
  provider text NOT NULL,
  subject text NOT NULL,
  linked_at timestamp with time zone NOT NULL DEFAULT now(),
  linked_by text
);

CREATE TABLE IF NOT EXISTS public.user_reports (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  reporter_id text NOT NULL,
  reported_user_id text NOT NULL,
  chat_id uuid,
  post_id uuid,
  message_id uuid,
  reason text NOT NULL,
  details text NOT NULL DEFAULT ''::text,
  status text NOT NULL DEFAULT 'new'::text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  target_type text NOT NULL,
  target_id text NOT NULL,
  application_id uuid,
  target_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  severity text NOT NULL DEFAULT 'medium'::text,
  evidence jsonb NOT NULL DEFAULT '[]'::jsonb,
  source text NOT NULL DEFAULT 'app_direct'::text,
  assigned_admin_id uuid,
  assigned_at timestamp with time zone,
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  resolved_at timestamp with time zone,
  resolved_by uuid,
  resolution text,
  resolution_reason text,
  severity_rank smallint GENERATED ALWAYS AS (
CASE severity
    WHEN 'critical'::text THEN 4
    WHEN 'high'::text THEN 3
    WHEN 'medium'::text THEN 2
    ELSE 1
END) STORED
);

CREATE TABLE IF NOT EXISTS public.users (
  id text NOT NULL,
  email text,
  name text DEFAULT ''::text,
  photo_url text,
  created_at timestamp with time zone DEFAULT now(),
  last_login timestamp with time zone DEFAULT now(),
  profile_image text,
  avatar_url text,
  phone text,
  phone_number text,
  notifications_enabled boolean DEFAULT true,
  language text DEFAULT 'en'::text,
  tos_accepted_at timestamp with time zone,
  fcm_tokens jsonb DEFAULT '[]'::jsonb,
  bio text,
  is_online boolean DEFAULT false,
  last_seen timestamp with time zone,
  profession text DEFAULT ''::text,
  average_rating double precision DEFAULT 0,
  total_reviews integer DEFAULT 0,
  completed_jobs_count integer DEFAULT 0,
  role text NOT NULL DEFAULT 'user'::text,
  is_banned boolean NOT NULL DEFAULT false,
  name_changed_at timestamp with time zone,
  is_verified boolean NOT NULL DEFAULT false,
  account_type text NOT NULL DEFAULT 'individual'::text,
  available_until timestamp with time zone
);

-- ── Constraints ──

ALTER TABLE public.admin_users ADD CONSTRAINT admin_users_pkey PRIMARY KEY (id);

ALTER TABLE public.applications ADD CONSTRAINT applications_pkey PRIMARY KEY (id);

ALTER TABLE public.categories ADD CONSTRAINT categories_pkey PRIMARY KEY (id);

ALTER TABLE public.chat_messages ADD CONSTRAINT chat_messages_pkey PRIMARY KEY (id);

ALTER TABLE public.chats ADD CONSTRAINT chats_pkey PRIMARY KEY (id);

ALTER TABLE public.dispute_decisions ADD CONSTRAINT dispute_decisions_pkey PRIMARY KEY (id);

ALTER TABLE public.disputes ADD CONSTRAINT disputes_pkey PRIMARY KEY (id);

ALTER TABLE public.escrow ADD CONSTRAINT escrow_pkey PRIMARY KEY (id);

ALTER TABLE public.fcm_tokens ADD CONSTRAINT fcm_tokens_pkey PRIMARY KEY (id);

ALTER TABLE public.job_completions ADD CONSTRAINT job_completions_pkey PRIMARY KEY (id);

ALTER TABLE public.notifications ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);

ALTER TABLE public.post_engagement ADD CONSTRAINT post_engagement_pkey PRIMARY KEY (post_id);

ALTER TABLE public.post_images ADD CONSTRAINT post_images_pkey PRIMARY KEY (id);

ALTER TABLE public.posts ADD CONSTRAINT posts_pkey PRIMARY KEY (id);

ALTER TABLE public.provider_reputation ADD CONSTRAINT provider_reputation_pkey PRIMARY KEY (provider_id);

ALTER TABLE public.reviews ADD CONSTRAINT reviews_pkey PRIMARY KEY (id);

ALTER TABLE public.saved_items ADD CONSTRAINT saved_items_pkey PRIMARY KEY (id);

ALTER TABLE public.settlements ADD CONSTRAINT settlements_pkey PRIMARY KEY (id);

ALTER TABLE public.transactions ADD CONSTRAINT transactions_pkey PRIMARY KEY (id);

ALTER TABLE public.user_auth_identities ADD CONSTRAINT user_auth_identities_pkey PRIMARY KEY (provider, subject);

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_pkey PRIMARY KEY (id);

ALTER TABLE public.users ADD CONSTRAINT users_pkey PRIMARY KEY (id);

ALTER TABLE public.admin_users ADD CONSTRAINT admin_users_email_key UNIQUE (email);

ALTER TABLE public.admin_users ADD CONSTRAINT admin_users_token_hash_key UNIQUE (token_hash);

ALTER TABLE public.applications ADD CONSTRAINT uq_applications_post_applicant UNIQUE (post_id, applicant_user_id);

ALTER TABLE public.categories ADD CONSTRAINT categories_name_key UNIQUE (name);

ALTER TABLE public.escrow ADD CONSTRAINT escrow_job_id_key UNIQUE (post_id);

ALTER TABLE public.fcm_tokens ADD CONSTRAINT fcm_tokens_token_unique UNIQUE (token);

ALTER TABLE public.reviews ADD CONSTRAINT reviews_one_per_post UNIQUE (post_id);

ALTER TABLE public.saved_items ADD CONSTRAINT saved_items_user_id_item_type_item_id_key UNIQUE (user_id, item_type, item_id);

ALTER TABLE public.user_auth_identities ADD CONSTRAINT user_auth_identities_one_per_provider UNIQUE (help24_user_id, provider);

ALTER TABLE public.admin_users ADD CONSTRAINT admin_users_role_check CHECK ((role = ANY (ARRAY['support_agent'::text, 'senior_admin'::text, 'super_admin'::text])));

ALTER TABLE public.categories ADD CONSTRAINT categories_schema_is_object CHECK (((question_schema IS NULL) OR (jsonb_typeof(question_schema) = 'object'::text)));

ALTER TABLE public.chat_messages ADD CONSTRAINT chat_messages_status_check CHECK ((status = ANY (ARRAY['sent'::text, 'seen'::text])));

ALTER TABLE public.chats ADD CONSTRAINT chats_user_order CHECK ((user1 < user2));

ALTER TABLE public.dispute_decisions ADD CONSTRAINT dispute_decisions_actor_present CHECK ((((decided_by_system = true) AND (admin_id IS NULL)) OR ((decided_by_system = false) AND (admin_id IS NOT NULL))));

ALTER TABLE public.dispute_decisions ADD CONSTRAINT dispute_decisions_client_refund_amount_check CHECK (((client_refund_amount IS NULL) OR (client_refund_amount >= 0)));

ALTER TABLE public.dispute_decisions ADD CONSTRAINT dispute_decisions_decision_type_check CHECK ((decision_type = ANY (ARRAY['FULL_REFUND'::text, 'FULL_RELEASE'::text, 'PARTIAL_SPLIT'::text, 'ESCALATE'::text])));

ALTER TABLE public.dispute_decisions ADD CONSTRAINT dispute_decisions_provider_amount_check CHECK (((provider_amount IS NULL) OR (provider_amount >= 0)));

ALTER TABLE public.disputes ADD CONSTRAINT disputes_buyer_refund_check CHECK ((buyer_refund >= 0));

ALTER TABLE public.disputes ADD CONSTRAINT disputes_priority_check CHECK ((priority = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text, 'critical'::text])));

ALTER TABLE public.disputes ADD CONSTRAINT disputes_provider_amount_check CHECK ((provider_amount >= 0));

ALTER TABLE public.disputes ADD CONSTRAINT disputes_raised_by_role_check CHECK (((raised_by_role IS NULL) OR (raised_by_role = ANY (ARRAY['client'::text, 'provider'::text]))));

ALTER TABLE public.disputes ADD CONSTRAINT disputes_status_check CHECK ((status = ANY (ARRAY['open'::text, 'reviewing'::text, 'resolved'::text, 'escalated'::text, 'merged'::text, 'awaiting_client_evidence'::text, 'awaiting_provider_evidence'::text, 'awaiting_admin_review'::text, 'under_review'::text, 'resolved_release'::text, 'resolved_refund'::text, 'resolved_partial'::text])));

ALTER TABLE public.escrow ADD CONSTRAINT escrow_amount_check CHECK ((amount > 0));

ALTER TABLE public.escrow ADD CONSTRAINT escrow_status_check CHECK ((status = ANY (ARRAY['locked'::text, 'payout_pending'::text, 'released'::text, 'disputed'::text, 'refunded'::text])));

ALTER TABLE public.job_completions ADD CONSTRAINT job_completions_status_check CHECK ((status = ANY (ARRAY['pending_approval'::text, 'approved'::text, 'disputed'::text])));

ALTER TABLE public.posts ADD CONSTRAINT posts_attributes_is_object CHECK ((jsonb_typeof(attributes) = 'object'::text));

ALTER TABLE public.posts ADD CONSTRAINT posts_employment_type_check CHECK (((employment_type IS NULL) OR (employment_type = ANY (ARRAY['full_time'::text, 'part_time'::text, 'contract'::text, 'temporary'::text]))));

ALTER TABLE public.posts ADD CONSTRAINT posts_pricing_type_check CHECK ((pricing_type = ANY (ARRAY['task'::text, 'hour'::text, 'day'::text, 'week'::text, 'month'::text])));

ALTER TABLE public.posts ADD CONSTRAINT posts_status_check CHECK ((status = ANY (ARRAY['open'::text, 'assigned'::text, 'completed'::text, 'disputed'::text, 'cancelled'::text])));

ALTER TABLE public.posts ADD CONSTRAINT posts_type_check CHECK ((type = ANY (ARRAY['request'::text, 'offer'::text, 'job'::text])));

ALTER TABLE public.posts ADD CONSTRAINT posts_urgency_check CHECK ((urgency = ANY (ARRAY['urgent'::text, 'soon'::text, 'flexible'::text])));

ALTER TABLE public.provider_reputation ADD CONSTRAINT provider_reputation_tier_check CHECK ((tier = ANY (ARRAY['new_provider'::text, 'rising_provider'::text, 'top_rated'::text, 'highly_recommended'::text, 'trusted_professional'::text])));

ALTER TABLE public.reviews ADD CONSTRAINT reviews_no_self CHECK ((client_id <> provider_id));

ALTER TABLE public.reviews ADD CONSTRAINT reviews_rating_check CHECK (((rating >= 1) AND (rating <= 5)));

ALTER TABLE public.reviews ADD CONSTRAINT reviews_status_check CHECK ((status = ANY (ARRAY['visible'::text, 'hidden'::text, 'flagged'::text])));

ALTER TABLE public.saved_items ADD CONSTRAINT saved_items_item_type_check CHECK ((item_type = ANY (ARRAY['post'::text, 'provider'::text])));

ALTER TABLE public.settlements ADD CONSTRAINT settlements_amount_check CHECK ((amount >= 0));

ALTER TABLE public.settlements ADD CONSTRAINT settlements_direction_check CHECK ((direction = ANY (ARRAY['provider_payout'::text, 'client_refund'::text, 'platform_fee'::text])));

ALTER TABLE public.settlements ADD CONSTRAINT settlements_environment_check CHECK ((environment = ANY (ARRAY['sandbox'::text, 'production'::text])));

ALTER TABLE public.settlements ADD CONSTRAINT settlements_rail_check CHECK ((rail = ANY (ARRAY['mpesa_b2c'::text, 'manual'::text, 'internal'::text])));

ALTER TABLE public.settlements ADD CONSTRAINT settlements_reason_ref_type_check CHECK ((reason_ref_type = ANY (ARRAY['dispute_decision'::text, 'job_approval'::text, 'legacy_admin_resolve'::text, 'backfill'::text])));

ALTER TABLE public.settlements ADD CONSTRAINT settlements_status_check CHECK ((status = ANY (ARRAY['initiated'::text, 'pending'::text, 'owed'::text, 'succeeded'::text, 'failed'::text, 'recorded'::text, 'completed'::text, 'voided'::text, 'retained'::text, 'refunded'::text])));

ALTER TABLE public.transactions ADD CONSTRAINT transactions_amount_check CHECK ((amount > 0));

ALTER TABLE public.transactions ADD CONSTRAINT transactions_fee_check CHECK ((fee >= 0));

ALTER TABLE public.transactions ADD CONSTRAINT transactions_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'paid'::text, 'failed'::text, 'payout_pending'::text, 'released'::text, 'disputed'::text, 'refunded'::text])));

ALTER TABLE public.transactions ADD CONSTRAINT transactions_total_paid_check CHECK ((total_paid > 0));

ALTER TABLE public.user_auth_identities ADD CONSTRAINT user_auth_identities_provider_check CHECK ((provider = ANY (ARRAY['firebase'::text, 'supabase'::text])));

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_assignment_consistent CHECK (((assigned_admin_id IS NULL) = (assigned_at IS NULL)));

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_details_length CHECK ((char_length(details) <= 2000));

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_evidence_shape CHECK (((jsonb_typeof(evidence) = 'array'::text) AND (jsonb_array_length(evidence) <= 5)));

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_not_self CHECK ((reporter_id <> reported_user_id));

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_reason_check CHECK ((reason = ANY (ARRAY['spam'::text, 'scam_or_fraud'::text, 'inappropriate_content'::text, 'harassment'::text, 'other'::text, 'suspicious_activity'::text, 'illegal_activity'::text, 'threats'::text, 'impersonation'::text, 'misleading_listing'::text, 'payment_issue'::text, 'unsafe_behavior'::text])));

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_resolution_check CHECK (((resolution IS NULL) OR (resolution = ANY (ARRAY['action_taken'::text, 'no_action'::text, 'dismissed'::text]))));

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_resolution_matches_status CHECK (((resolution IS NULL) OR ((status = 'dismissed'::text) = (resolution = 'dismissed'::text))));

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_severity_check CHECK ((severity = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text, 'critical'::text])));

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_source_check CHECK ((source = ANY (ARRAY['api'::text, 'app_direct'::text])));

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_status_check CHECK ((status = ANY (ARRAY['new'::text, 'under_review'::text, 'action_required'::text, 'resolved'::text, 'dismissed'::text])));

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_target_type_check CHECK ((target_type = ANY (ARRAY['user'::text, 'post'::text, 'application'::text, 'message'::text])));

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_terminal_consistent CHECK (((status = ANY (ARRAY['resolved'::text, 'dismissed'::text])) = ((resolved_at IS NOT NULL) AND (resolution IS NOT NULL))));

ALTER TABLE public.users ADD CONSTRAINT users_account_type_check CHECK ((account_type = ANY (ARRAY['individual'::text, 'business'::text])));

ALTER TABLE public.users ADD CONSTRAINT users_role_check CHECK ((role = ANY (ARRAY['user'::text, 'admin'::text])));

ALTER TABLE public.applications ADD CONSTRAINT applications_applicant_user_id_fkey FOREIGN KEY (applicant_user_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE public.applications ADD CONSTRAINT applications_post_id_fkey FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE;

ALTER TABLE public.chat_messages ADD CONSTRAINT chat_messages_chat_fkey FOREIGN KEY (chat_id) REFERENCES chats(id) ON DELETE CASCADE;

ALTER TABLE public.chats ADD CONSTRAINT chats_post_id_fkey FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE SET NULL;

ALTER TABLE public.dispute_decisions ADD CONSTRAINT dispute_decisions_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES admin_users(id) ON DELETE RESTRICT;

ALTER TABLE public.dispute_decisions ADD CONSTRAINT dispute_decisions_dispute_id_fkey FOREIGN KEY (dispute_id) REFERENCES disputes(id) ON DELETE RESTRICT;

ALTER TABLE public.disputes ADD CONSTRAINT disputes_assigned_admin_fkey FOREIGN KEY (assigned_admin_id) REFERENCES admin_users(id) ON DELETE SET NULL;

ALTER TABLE public.disputes ADD CONSTRAINT disputes_job_completion_id_fkey FOREIGN KEY (job_completion_id) REFERENCES job_completions(id) ON DELETE SET NULL;

ALTER TABLE public.disputes ADD CONSTRAINT disputes_merged_into_fkey FOREIGN KEY (merged_into_dispute_id) REFERENCES disputes(id) ON DELETE SET NULL;

ALTER TABLE public.disputes ADD CONSTRAINT disputes_post_id_fkey FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE;

ALTER TABLE public.disputes ADD CONSTRAINT disputes_raised_by_user_id_fkey FOREIGN KEY (raised_by_user_id) REFERENCES users(id);

ALTER TABLE public.disputes ADD CONSTRAINT disputes_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE RESTRICT;

ALTER TABLE public.escrow ADD CONSTRAINT escrow_provider_user_id_fkey FOREIGN KEY (provider_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE public.escrow ADD CONSTRAINT escrow_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE RESTRICT;

ALTER TABLE public.fcm_tokens ADD CONSTRAINT fcm_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE public.job_completions ADD CONSTRAINT job_completions_client_user_id_fkey FOREIGN KEY (client_user_id) REFERENCES users(id);

ALTER TABLE public.job_completions ADD CONSTRAINT job_completions_post_id_fkey FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE;

ALTER TABLE public.job_completions ADD CONSTRAINT job_completions_provider_user_id_fkey FOREIGN KEY (provider_user_id) REFERENCES users(id);

ALTER TABLE public.job_completions ADD CONSTRAINT job_completions_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE RESTRICT;

ALTER TABLE public.notifications ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE public.post_images ADD CONSTRAINT post_images_post_id_fkey FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE;

ALTER TABLE public.posts ADD CONSTRAINT posts_author_user_id_fkey FOREIGN KEY (author_user_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE public.provider_reputation ADD CONSTRAINT provider_reputation_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE public.reviews ADD CONSTRAINT reviews_post_id_fkey FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE;

ALTER TABLE public.saved_items ADD CONSTRAINT saved_items_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE public.settlements ADD CONSTRAINT settlements_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE RESTRICT;

ALTER TABLE public.user_auth_identities ADD CONSTRAINT user_auth_identities_help24_user_id_fkey FOREIGN KEY (help24_user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_assigned_admin_fkey FOREIGN KEY (assigned_admin_id) REFERENCES admin_users(id) ON DELETE RESTRICT;

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_reported_user_id_fkey FOREIGN KEY (reported_user_id) REFERENCES users(id) ON DELETE RESTRICT;

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_reporter_id_fkey FOREIGN KEY (reporter_id) REFERENCES users(id) ON DELETE RESTRICT;

ALTER TABLE public.user_reports ADD CONSTRAINT user_reports_resolved_by_fkey FOREIGN KEY (resolved_by) REFERENCES admin_users(id) ON DELETE RESTRICT;

-- ── Indexes ──

CREATE INDEX idx_admin_users_active ON public.admin_users USING btree (active) WHERE (active = true);

CREATE INDEX idx_admin_users_token_hash ON public.admin_users USING btree (token_hash);

CREATE UNIQUE INDEX uniq_admin_users_email ON public.admin_users USING btree (email);

CREATE UNIQUE INDEX uniq_admin_users_token_hash ON public.admin_users USING btree (token_hash);

CREATE INDEX idx_applications_applicant_post ON public.applications USING btree (applicant_user_id, post_id);

CREATE INDEX idx_applications_applicant_temp_id ON public.applications USING btree (applicant_temp_id);

CREATE INDEX idx_applications_applicant_user_id ON public.applications USING btree (applicant_user_id);

CREATE INDEX idx_applications_created_at ON public.applications USING btree (created_at DESC);

CREATE INDEX idx_applications_post_applicant ON public.applications USING btree (post_id, applicant_user_id);

CREATE INDEX idx_applications_post_id ON public.applications USING btree (post_id);

CREATE INDEX idx_chat_messages_chat_created ON public.chat_messages USING btree (chat_id, created_at DESC);

CREATE INDEX idx_chat_messages_chat_id ON public.chat_messages USING btree (chat_id);

CREATE INDEX idx_chat_messages_chat_status ON public.chat_messages USING btree (chat_id, status);

CREATE INDEX idx_chat_messages_created_at ON public.chat_messages USING btree (created_at);

CREATE INDEX idx_chat_messages_deleted ON public.chat_messages USING btree (chat_id, deleted_at) WHERE (deleted_for_everyone = true);

CREATE INDEX idx_chat_messages_reply_to ON public.chat_messages USING btree (reply_to_id) WHERE (reply_to_id IS NOT NULL);

CREATE INDEX idx_chat_messages_sender_id ON public.chat_messages USING btree (sender_id);

CREATE INDEX idx_chat_messages_unseen ON public.chat_messages USING btree (chat_id, sender_id, status) WHERE (status = 'sent'::text);

CREATE INDEX idx_chats_participants ON public.chats USING btree (user1, user2);

CREATE INDEX idx_chats_post_id ON public.chats USING btree (post_id);

CREATE UNIQUE INDEX idx_chats_unique_null ON public.chats USING btree (user1, user2) WHERE (post_id IS NULL);

CREATE UNIQUE INDEX idx_chats_unique_post ON public.chats USING btree (user1, user2, post_id) WHERE (post_id IS NOT NULL);

CREATE INDEX idx_chats_updated_at ON public.chats USING btree (updated_at DESC);

CREATE INDEX idx_chats_user1 ON public.chats USING btree (user1);

CREATE INDEX idx_chats_user1_user2 ON public.chats USING btree (user1, user2);

CREATE INDEX idx_chats_user2 ON public.chats USING btree (user2);

CREATE INDEX idx_dispute_decisions_admin ON public.dispute_decisions USING btree (admin_id);

CREATE INDEX idx_dispute_decisions_dispute ON public.dispute_decisions USING btree (dispute_id, created_at);

CREATE INDEX idx_disputes_assigned ON public.disputes USING btree (assigned_admin_id);

CREATE INDEX idx_disputes_created_at ON public.disputes USING btree (created_at DESC);

CREATE INDEX idx_disputes_open_age ON public.disputes USING btree (created_at) WHERE (status = ANY (ARRAY['open'::text, 'reviewing'::text, 'under_review'::text]));

CREATE INDEX idx_disputes_post_id ON public.disputes USING btree (post_id);

CREATE INDEX idx_disputes_priority ON public.disputes USING btree (priority);

CREATE INDEX idx_disputes_status ON public.disputes USING btree (status);

CREATE INDEX idx_disputes_transaction_id ON public.disputes USING btree (transaction_id);

CREATE INDEX escrow_payout_destination_idx ON public.escrow USING btree (payout_destination_id) WHERE (payout_destination_id IS NOT NULL);

CREATE INDEX idx_escrow_job_id ON public.escrow USING btree (post_id);

CREATE INDEX idx_escrow_post_id ON public.escrow USING btree (post_id);

CREATE INDEX idx_escrow_status ON public.escrow USING btree (status);

CREATE INDEX idx_escrow_transaction_id ON public.escrow USING btree (transaction_id);

CREATE INDEX idx_fcm_tokens_user_id ON public.fcm_tokens USING btree (user_id);

CREATE INDEX idx_job_completions_client ON public.job_completions USING btree (client_user_id);

CREATE INDEX idx_job_completions_post_id ON public.job_completions USING btree (post_id);

CREATE INDEX idx_job_completions_provider ON public.job_completions USING btree (provider_user_id);

CREATE INDEX idx_job_completions_status ON public.job_completions USING btree (status);

CREATE UNIQUE INDEX uq_job_completions_post_pending ON public.job_completions USING btree (post_id) WHERE (status = 'pending_approval'::text);

CREATE INDEX idx_notifications_user_id ON public.notifications USING btree (user_id);

CREATE INDEX idx_notifications_user_unread ON public.notifications USING btree (user_id, read, created_at DESC);

CREATE INDEX idx_post_images_post_id ON public.post_images USING btree (post_id);

CREATE INDEX idx_posts_active ON public.posts USING btree (created_at DESC) WHERE (archived_at IS NULL);

CREATE INDEX idx_posts_author_temp_id ON public.posts USING btree (author_temp_id);

CREATE INDEX idx_posts_author_user_id ON public.posts USING btree (author_user_id);

CREATE INDEX idx_posts_category ON public.posts USING btree (category);

CREATE INDEX idx_posts_created_at ON public.posts USING btree (created_at DESC);

CREATE INDEX idx_posts_description_trgm ON public.posts USING gin (description gin_trgm_ops);

CREATE INDEX idx_posts_feed_author ON public.posts USING btree (author_user_id, created_at DESC) WHERE ((archived_at IS NULL) AND (status = 'open'::text));

CREATE INDEX idx_posts_feed_category ON public.posts USING btree (category, created_at DESC) WHERE ((archived_at IS NULL) AND (status = 'open'::text));

CREATE INDEX idx_posts_feed_geo ON public.posts USING btree (latitude, longitude, created_at DESC) WHERE ((archived_at IS NULL) AND (status = 'open'::text) AND (latitude IS NOT NULL));

CREATE INDEX idx_posts_feed_live ON public.posts USING btree (created_at DESC) WHERE ((archived_at IS NULL) AND (status = 'open'::text));

CREATE INDEX idx_posts_feed_type ON public.posts USING btree (type, created_at DESC) WHERE ((archived_at IS NULL) AND (status = 'open'::text));

CREATE INDEX idx_posts_feed_urgent ON public.posts USING btree (urgent_expires_at DESC) WHERE ((archived_at IS NULL) AND (status = 'open'::text) AND (is_urgent = true));

CREATE INDEX idx_posts_is_urgent ON public.posts USING btree (is_urgent);

CREATE INDEX idx_posts_lat_lng ON public.posts USING btree (latitude, longitude);

CREATE INDEX idx_posts_location ON public.posts USING btree (location);

CREATE INDEX idx_posts_location_trgm ON public.posts USING gin (location gin_trgm_ops);

CREATE INDEX idx_posts_selected_provider_id ON public.posts USING btree (selected_provider_id) WHERE (selected_provider_id IS NOT NULL);

CREATE INDEX idx_posts_status ON public.posts USING btree (status);

CREATE INDEX idx_posts_title_trgm ON public.posts USING gin (title gin_trgm_ops);

CREATE INDEX idx_posts_type ON public.posts USING btree (type);

CREATE INDEX idx_posts_urgency ON public.posts USING btree (urgency);

CREATE INDEX idx_posts_urgent_expires_at ON public.posts USING btree (urgent_expires_at);

CREATE INDEX idx_reviews_client ON public.reviews USING btree (client_id);

CREATE INDEX idx_reviews_provider ON public.reviews USING btree (provider_id, created_at DESC);

CREATE INDEX idx_saved_items_user_created ON public.saved_items USING btree (user_id, created_at DESC);

CREATE INDEX idx_settlements_conversation ON public.settlements USING btree (conversation_id);

CREATE INDEX idx_settlements_environment ON public.settlements USING btree (environment);

CREATE INDEX idx_settlements_open ON public.settlements USING btree (status) WHERE (status = ANY (ARRAY['initiated'::text, 'pending'::text, 'recorded'::text, 'owed'::text]));

CREATE INDEX idx_settlements_originator ON public.settlements USING btree (originator_conversation_id);

CREATE INDEX idx_settlements_transaction ON public.settlements USING btree (transaction_id);

CREATE UNIQUE INDEX uq_settlements_active_leg ON public.settlements USING btree (transaction_id, direction) WHERE (status = ANY (ARRAY['initiated'::text, 'pending'::text, 'owed'::text, 'succeeded'::text, 'recorded'::text, 'completed'::text, 'retained'::text, 'refunded'::text]));

CREATE INDEX idx_transactions_checkout_request_id ON public.transactions USING btree (checkout_request_id);

CREATE INDEX idx_transactions_conversation_id ON public.transactions USING btree (conversation_id);

CREATE INDEX idx_transactions_created_at ON public.transactions USING btree (created_at DESC);

CREATE INDEX idx_transactions_originator_conversation_id ON public.transactions USING btree (originator_conversation_id);

CREATE INDEX idx_transactions_post_id ON public.transactions USING btree (post_id);

CREATE INDEX idx_transactions_status ON public.transactions USING btree (status);

CREATE INDEX transactions_payout_destination_idx ON public.transactions USING btree (payout_destination_id) WHERE (payout_destination_id IS NOT NULL);

CREATE INDEX idx_user_auth_identities_user ON public.user_auth_identities USING btree (help24_user_id);

CREATE INDEX idx_user_reports_open_assignee ON public.user_reports USING btree (assigned_admin_id) WHERE (status = ANY (ARRAY['new'::text, 'under_review'::text, 'action_required'::text]));

CREATE INDEX idx_user_reports_open_severity ON public.user_reports USING btree (severity_rank DESC, created_at) WHERE (status = ANY (ARRAY['new'::text, 'under_review'::text, 'action_required'::text]));

CREATE INDEX idx_user_reports_reason ON public.user_reports USING btree (reason, created_at DESC);

CREATE INDEX idx_user_reports_reported_user ON public.user_reports USING btree (reported_user_id, created_at DESC);

CREATE INDEX idx_user_reports_reporter ON public.user_reports USING btree (reporter_id, created_at DESC);

CREATE INDEX idx_user_reports_status_created ON public.user_reports USING btree (status, created_at DESC);

CREATE INDEX idx_user_reports_target ON public.user_reports USING btree (target_type, target_id);

CREATE UNIQUE INDEX user_reports_one_open_per_target ON public.user_reports USING btree (reporter_id, target_type, target_id) WHERE (status = ANY (ARRAY['new'::text, 'under_review'::text, 'action_required'::text]));

CREATE INDEX idx_users_available_until ON public.users USING btree (available_until) WHERE (available_until IS NOT NULL);

CREATE INDEX idx_users_created_at ON public.users USING btree (created_at DESC);

CREATE INDEX idx_users_email ON public.users USING btree (email);

CREATE INDEX idx_users_is_banned ON public.users USING btree (is_banned) WHERE (is_banned = true);

CREATE INDEX idx_users_phone_number ON public.users USING btree (phone_number) WHERE (phone_number IS NOT NULL);

CREATE INDEX idx_users_profession ON public.users USING btree (profession) WHERE ((profession IS NOT NULL) AND (profession <> ''::text));

CREATE INDEX idx_users_role ON public.users USING btree (role) WHERE (role = 'admin'::text);

CREATE UNIQUE INDEX users_email_unique ON public.users USING btree (lower(email)) WHERE ((email IS NOT NULL) AND (email <> ''::text));

-- ── Trigger functions ──

CREATE OR REPLACE FUNCTION public.fn_block_decision_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  RAISE EXCEPTION 'dispute_decisions is an immutable audit log — % is not permitted', TG_OP
    USING ERRCODE = 'restrict_violation';
END $function$
;

CREATE OR REPLACE FUNCTION public.fn_block_self_application()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_author TEXT;
BEGIN
  SELECT author_user_id INTO v_author
    FROM public.posts WHERE id = NEW.post_id;

  IF v_author IS NOT NULL AND NEW.applicant_user_id = v_author THEN
    RAISE EXCEPTION 'You cannot apply to your own post.'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_chat_messages_undelete_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.fn_moderation_enforce()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.fn_moderation_history_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  RAISE EXCEPTION 'HELP24_MODERATION_HISTORY_IMMUTABLE: % on %.% is not permitted',
    TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = '42501',
          HINT = 'Moderation history is append-only. Record a new action instead.';
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_posts_moderation_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.fn_touch_post_engagement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_post_id TEXT;
BEGIN
  -- Each source table names the post differently; TG_ARGV[0] carries the column.
  -- Read through to_jsonb rather than dynamic SQL: `($1).col` on a record passed
  -- via USING has no resolvable type at plan time and fails at runtime.
  IF TG_OP = 'DELETE' THEN
    v_post_id := to_jsonb(OLD) ->> TG_ARGV[0];
  ELSE
    v_post_id := to_jsonb(NEW) ->> TG_ARGV[0];
  END IF;

  -- saved_items spans posts AND providers; only post rows are engagement.
  IF TG_TABLE_NAME = 'saved_items' THEN
    IF (TG_OP = 'DELETE' AND OLD.item_type <> 'post')
       OR (TG_OP <> 'DELETE' AND NEW.item_type <> 'post') THEN
      RETURN NULL;
    END IF;
  END IF;

  IF v_post_id IS NOT NULL AND v_post_id <> '' THEN
    -- A DERIVED COUNTER MUST NEVER FAIL A REAL WRITE.
    --
    -- This is the fix for the CLASS of bug, not just the instance. 092's own
    -- contract says these counters are "derived… repairable… never a source of
    -- truth" — and yet an unhandled error in maintaining them aborted the
    -- user's application. A ranking optimisation was given veto power over the
    -- business action it was measuring, which is exactly backwards.
    --
    -- Any failure here is now contained: the application or save COMMITS, and
    -- the counter is left stale. Stale is the designed-for state — the recompute
    -- is idempotent and the next event on this post, or a manual call, repairs
    -- it from canonical tables.
    --
    -- RAISE WARNING, not silence: this lands in the Postgres log, so a
    -- persistent fault is visible in operations rather than merely invisible to
    -- users. (Suppressing a non-essential background failure from the USER is
    -- correct; hiding it from the OPERATOR is not.)
    BEGIN
      PERFORM public.fn_recompute_post_engagement(v_post_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'post_engagement recompute failed for % (%): %',
        v_post_id, SQLSTATE, SQLERRM;
    END;
  END IF;
  RETURN NULL;  -- AFTER trigger; return value is ignored
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_user_reports_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'HELP24_MODERATION_HISTORY_IMMUTABLE: reports are evidence and are never deleted'
      USING ERRCODE = '42501';
  END IF;

  IF (NEW.id, NEW.reporter_id, NEW.reported_user_id, NEW.target_type, NEW.target_id, NEW.reason,
      NEW.details, NEW.evidence, NEW.target_snapshot, NEW.chat_id, NEW.post_id, NEW.message_id,
      NEW.application_id, NEW.source, NEW.created_at)
     IS DISTINCT FROM
     (OLD.id, OLD.reporter_id, OLD.reported_user_id, OLD.target_type, OLD.target_id, OLD.reason,
      OLD.details, OLD.evidence, OLD.target_snapshot, OLD.chat_id, OLD.post_id, OLD.message_id,
      OLD.application_id, OLD.source, OLD.created_at) THEN
    RAISE EXCEPTION 'HELP24_REPORT_IMMUTABLE: a report cannot be edited after it is filed'
      USING ERRCODE = '42501';
  END IF;

  IF coalesce(current_setting('help24.moderation_write', true), '') <> 'on' THEN
    RAISE EXCEPTION 'HELP24_MODERATION_WRITE_REQUIRED: report triage changes only through the moderation functions'
      USING ERRCODE = '42501';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_user_reports_prepare()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c_uuid     CONSTANT text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  v_trusted  boolean := public.moderation_caller_is_trusted();
  v_reported text;
  v_user     public.users%ROWTYPE;
  v_post     public.posts%ROWTYPE;
  v_app      public.applications%ROWTYPE;
  v_msg      public.chat_messages%ROWTYPE;
  v_chat     public.chats%ROWTYPE;
  v_item     jsonb;
  v_count    integer;
BEGIN
  -- ── 1. Server-owned columns ──────────────────────────────────────────────
  -- Whatever the caller sent is discarded. Triage state is written only by the
  -- migration-115 functions; a client inserting `status = 'dismissed'` or its
  -- own severity simply does not get to.
  NEW.status            := 'new';
  NEW.assigned_admin_id := NULL;
  NEW.assigned_at       := NULL;
  NEW.resolved_at       := NULL;
  NEW.resolved_by       := NULL;
  NEW.resolution        := NULL;
  NEW.resolution_reason := NULL;
  NEW.created_at        := now();
  NEW.updated_at        := now();
  NEW.details           := btrim(coalesce(NEW.details, ''));
  NEW.target_snapshot   := '{}'::jsonb;

  IF v_trusted THEN
    NEW.source := coalesce(NEW.source, 'api');
    -- Evidence must be the REPORTER'S OWN uploads. The backend issues upload
    -- paths under reports/<reporter>/, and this refuses anything else — a
    -- reference to somebody else's file is not evidence, it is a leak.
    FOR v_item IN SELECT * FROM jsonb_array_elements(coalesce(NEW.evidence, '[]'::jsonb)) LOOP
      IF jsonb_typeof(v_item) <> 'object'
         OR jsonb_typeof(v_item -> 'path') <> 'string'
         OR (v_item ->> 'path') NOT LIKE ('reports/' || NEW.reporter_id || '/%') THEN
        RAISE EXCEPTION 'HELP24_REPORT_INVALID_EVIDENCE: evidence must be your own upload'
          USING ERRCODE = '22023';
      END IF;
    END LOOP;
  ELSE
    -- The direct-insert door cannot attach evidence at all: nothing on that
    -- path has checked what a path points at.
    NEW.source   := 'app_direct';
    NEW.evidence := '[]'::jsonb;
  END IF;

  -- ── 2. Resolve the target; DERIVE the reported person ───────────────────
  -- The shipped app sends the 084 shape (reported_user_id + optional
  -- message_id) and no target at all. Translate it.
  IF NEW.target_type IS NULL THEN
    NEW.target_type := CASE WHEN NEW.message_id IS NOT NULL THEN 'message' ELSE 'user' END;
    NEW.target_id   := CASE WHEN NEW.message_id IS NOT NULL THEN NEW.message_id::text ELSE NEW.reported_user_id END;
  END IF;
  NEW.target_id := btrim(coalesce(NEW.target_id, ''));
  IF NEW.target_id = '' THEN
    RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: a target is required' USING ERRCODE = '22023';
  END IF;

  IF NEW.target_type IN ('post', 'application', 'message') AND NEW.target_id !~* c_uuid THEN
    RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: malformed id' USING ERRCODE = '22023';
  END IF;

  CASE NEW.target_type
    WHEN 'user' THEN
      SELECT * INTO v_user FROM public.users WHERE id = NEW.target_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: account not found' USING ERRCODE = '22023';
      END IF;
      v_reported := v_user.id;
      NEW.target_snapshot := jsonb_build_object(
        'name',         v_user.name,
        'bio',          left(coalesce(v_user.bio, ''), 2000),
        'profession',   v_user.profession,
        'avatar_url',   coalesce(nullif(v_user.avatar_url, ''), v_user.profile_image),
        'member_since', v_user.created_at);

    WHEN 'post' THEN
      SELECT * INTO v_post FROM public.posts WHERE id = NEW.target_id::uuid;
      IF NOT FOUND OR v_post.author_user_id IS NULL THEN
        RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: listing not found' USING ERRCODE = '22023';
      END IF;
      v_reported  := v_post.author_user_id;
      NEW.post_id := v_post.id;
      NEW.target_snapshot := jsonb_build_object(
        'type',        v_post.type,
        'title',       v_post.title,
        'description', left(coalesce(v_post.description, ''), 4000),
        'category',    v_post.category,
        'location',    v_post.location,
        'price',       v_post.price,
        'status',      v_post.status,
        'created_at',  v_post.created_at);

    WHEN 'application' THEN
      SELECT * INTO v_app FROM public.applications WHERE id = NEW.target_id::uuid;
      IF NOT FOUND OR v_app.applicant_user_id IS NULL THEN
        RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: application not found' USING ERRCODE = '22023';
      END IF;
      SELECT * INTO v_post FROM public.posts WHERE id = v_app.post_id;
      -- Applicants are shown to the listing's owner, and only the owner has a
      -- reason to be reading one.
      IF NOT FOUND OR v_post.author_user_id IS DISTINCT FROM NEW.reporter_id THEN
        RAISE EXCEPTION 'HELP24_REPORT_NOT_PARTICIPANT: only the listing owner can report an application'
          USING ERRCODE = '42501';
      END IF;
      v_reported         := v_app.applicant_user_id;
      NEW.application_id := v_app.id;
      NEW.post_id        := v_app.post_id;
      NEW.target_snapshot := jsonb_build_object(
        'message',        left(coalesce(v_app.message, ''), 4000),
        'proposed_price', v_app.proposed_price,
        'applied_at',     v_app.created_at,
        'post_title',     v_post.title,
        'post_type',      v_post.type);

    WHEN 'message' THEN
      SELECT * INTO v_msg FROM public.chat_messages WHERE id = NEW.target_id::uuid;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: message not found' USING ERRCODE = '22023';
      END IF;
      SELECT * INTO v_chat FROM public.chats WHERE id = v_msg.chat_id;
      -- You can report what was said TO you, in a conversation you are in.
      IF NOT FOUND OR NEW.reporter_id NOT IN (v_chat.user1, v_chat.user2) THEN
        RAISE EXCEPTION 'HELP24_REPORT_NOT_PARTICIPANT: you can only report messages in your own conversations'
          USING ERRCODE = '42501';
      END IF;
      v_reported     := v_msg.sender_id;
      NEW.message_id := v_msg.id;
      NEW.chat_id    := v_msg.chat_id;
      -- The conversation says which listing it is about; the client does not.
      NEW.post_id    := v_chat.post_id;
      NEW.target_snapshot := jsonb_build_object(
        'content',              left(coalesce(v_msg.content, ''), 4000),
        'type',                 v_msg.type,
        'attachment_url',       v_msg.attachment_url,
        'sent_at',              v_msg.created_at,
        'deleted_for_everyone', v_msg.deleted_for_everyone);

    ELSE
      RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: unknown target type %', NEW.target_type
        USING ERRCODE = '22023';
  END CASE;

  -- The shipped client still sends reported_user_id. It must agree with what
  -- the target says; a mismatch is someone aiming a report at a bystander.
  IF NEW.reported_user_id IS NOT NULL AND NEW.reported_user_id <> v_reported THEN
    RAISE EXCEPTION 'HELP24_REPORT_INVALID_TARGET: the reported account does not match the target'
      USING ERRCODE = '22023';
  END IF;
  NEW.reported_user_id := v_reported;

  IF NEW.reporter_id = NEW.reported_user_id THEN
    RAISE EXCEPTION 'HELP24_REPORT_SELF: you cannot report yourself' USING ERRCODE = '23514';
  END IF;

  -- A person reported from a listing: keep that context only when the listing
  -- actually involves one of them (theirs, or the reporter's own that they
  -- answered). Context that points at an unrelated listing is dropped, not
  -- trusted.
  IF NEW.target_type = 'user' AND NEW.post_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.posts p
       WHERE p.id = NEW.post_id
         AND (p.author_user_id IN (NEW.reporter_id, NEW.reported_user_id)
              OR EXISTS (SELECT 1 FROM public.applications a
                          WHERE a.post_id = p.id
                            AND a.applicant_user_id IN (NEW.reporter_id, NEW.reported_user_id)))) THEN
      NEW.post_id := NULL;
    END IF;
  END IF;

  -- A person reported from inside a conversation: both must be in it.
  IF NEW.chat_id IS NOT NULL THEN
    SELECT * INTO v_chat FROM public.chats WHERE id = NEW.chat_id;
    IF NOT FOUND
       OR NEW.reporter_id NOT IN (v_chat.user1, v_chat.user2)
       OR NEW.reported_user_id NOT IN (v_chat.user1, v_chat.user2) THEN
      RAISE EXCEPTION 'HELP24_REPORT_NOT_PARTICIPANT: that conversation is not between you and this account'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- ── 3. The category must make sense for the target ─────────────────────
  IF NOT (NEW.reason = ANY (public.moderation_report_categories(NEW.target_type))) THEN
    RAISE EXCEPTION 'HELP24_REPORT_INVALID_CATEGORY: % does not apply to a %', NEW.reason, NEW.target_type
      USING ERRCODE = '22023';
  END IF;

  -- ── 4. Abuse controls ──────────────────────────────────────────────────
  -- Same person, same thing, within a day: already heard. (Still-open
  -- duplicates older than a day are caught by user_reports_one_open_per_target.)
  IF EXISTS (
    SELECT 1 FROM public.user_reports r
     WHERE r.reporter_id = NEW.reporter_id
       AND r.target_type = NEW.target_type
       AND r.target_id   = NEW.target_id
       AND r.created_at  > now() - interval '24 hours') THEN
    RAISE EXCEPTION 'HELP24_REPORT_DUPLICATE: you have already reported this' USING ERRCODE = 'P0001';
  END IF;

  -- Volume. Ten a day is far past anyone reporting honestly and well short of
  -- someone trying to bury the queue; five against one account stops a feud
  -- from being fought through the report button.
  SELECT count(*) INTO v_count
    FROM public.user_reports r
   WHERE r.reporter_id = NEW.reporter_id
     AND r.created_at > now() - interval '24 hours';
  IF v_count >= 10 THEN
    RAISE EXCEPTION 'HELP24_REPORT_LIMIT: too many reports today' USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*) INTO v_count
    FROM public.user_reports r
   WHERE r.reporter_id = NEW.reporter_id
     AND r.reported_user_id = NEW.reported_user_id
     AND r.created_at > now() - interval '24 hours';
  IF v_count >= 5 THEN
    RAISE EXCEPTION 'HELP24_REPORT_LIMIT: too many reports about this account today' USING ERRCODE = 'P0001';
  END IF;

  -- ── 5. Where it lands in the queue ──────────────────────────────────────
  NEW.severity := public.moderation_initial_severity(NEW.reason, NEW.reported_user_id, NEW.reporter_id);

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_users_guard_privileged_columns()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_jwt_role text;
BEGIN
  v_jwt_role := COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '');

  IF v_jwt_role = 'service_role'
     OR current_user IN ('postgres', 'supabase_admin', 'service_role') THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.role                 := 'user';
    NEW.is_banned            := false;
    NEW.is_verified          := false;
    NEW.average_rating       := NULL;
    NEW.total_reviews        := NULL;
    NEW.completed_jobs_count := NULL;
    RETURN NEW;
  END IF;

  IF NEW.id                   IS DISTINCT FROM OLD.id
  OR NEW.email                IS DISTINCT FROM OLD.email
  OR NEW.role                 IS DISTINCT FROM OLD.role
  OR NEW.is_banned            IS DISTINCT FROM OLD.is_banned
  OR NEW.is_verified          IS DISTINCT FROM OLD.is_verified
  OR NEW.average_rating       IS DISTINCT FROM OLD.average_rating
  OR NEW.total_reviews        IS DISTINCT FROM OLD.total_reviews
  OR NEW.completed_jobs_count IS DISTINCT FROM OLD.completed_jobs_count THEN
    RAISE EXCEPTION 'help24_privileged_column_change_refused'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_users_is_banned_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.is_banned IS DISTINCT FROM OLD.is_banned
     AND coalesce(current_setting('help24.moderation_write', true), '') <> 'on' THEN
    RAISE EXCEPTION 'HELP24_MODERATION_WRITE_REQUIRED: users.is_banned mirrors account_restrictions and changes only through the moderation functions'
      USING ERRCODE = '42501',
            HINT = 'Use moderation_apply_sanction / moderation_lift_restriction (migration 115).';
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_users_name_change_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  cooldown CONSTANT INTERVAL := INTERVAL '30 days';
  next_allowed TIMESTAMPTZ;
BEGIN
  -- Not a name change (the overwhelmingly common case: avatar, bio,
  -- profession, presence, prefs). Freeze the stamp so it cannot be forged,
  -- and get out of the way.
  IF NEW.name IS NOT DISTINCT FROM OLD.name THEN
    NEW.name_changed_at := OLD.name_changed_at;
    RETURN NEW;
  END IF;

  -- First-ever change is always allowed, including for every user who existed
  -- before this migration.
  IF OLD.name_changed_at IS NOT NULL THEN
    next_allowed := OLD.name_changed_at + cooldown;
    IF now() < next_allowed THEN
      RAISE EXCEPTION
        'HELP24_NAME_COOLDOWN: name can change again after %', next_allowed
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  NEW.name_changed_at := now();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.increment_unread_count()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_user1 TEXT;
  v_user2 TEXT;
BEGIN
  SELECT user1, user2
    INTO v_user1, v_user2
    FROM chats
   WHERE id = NEW.chat_id;

  IF v_user1 IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.sender_id = v_user1 THEN
    UPDATE chats
       SET user2_unread_count = user2_unread_count + 1
     WHERE id = NEW.chat_id;
  ELSE
    UPDATE chats
       SET user1_unread_count = user1_unread_count + 1
     WHERE id = NEW.chat_id;
  END IF;

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.posts_validate_job_employment_type()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.type = 'job' AND (NEW.employment_type IS NULL OR NEW.employment_type = '') THEN
    -- Only enforce on INSERT, or when type is being changed TO 'job' for this row.
    -- Cascaded UPDATEs that touch other columns leave OLD.type = NEW.type = 'job',
    -- so this branch is skipped — no spurious exceptions.
    IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.type IS DISTINCT FROM 'job') THEN
      RAISE EXCEPTION 'employment_type is required when type is job';
    END IF;
  END IF;

  -- Clear employment_type for non-job rows (only on INSERT or explicit type change)
  IF NEW.type != 'job' THEN
    IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.type IS DISTINCT FROM NEW.type) THEN
      NEW.employment_type := NULL;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.trg_posts_reputation_recompute()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  -- Only the concluded states ('completed','cancelled') and the provider
  -- assignment feed the rate math — skip unrelated transitions.
  IF NEW.selected_provider_id IS NOT NULL
     AND (
       (OLD.status IS DISTINCT FROM NEW.status
        AND (OLD.status IN ('completed','cancelled') OR NEW.status IN ('completed','cancelled')))
       OR OLD.selected_provider_id IS DISTINCT FROM NEW.selected_provider_id
     ) THEN
    PERFORM public.fn_recompute_provider_reputation(NEW.selected_provider_id);
  END IF;
  -- Provider reassigned away: the OLD provider's denominators change too.
  IF OLD.selected_provider_id IS NOT NULL
     AND OLD.selected_provider_id IS DISTINCT FROM NEW.selected_provider_id THEN
    PERFORM public.fn_recompute_provider_reputation(OLD.selected_provider_id);
  END IF;
  RETURN NEW;
END;
$function$
;

-- ── Triggers ──

CREATE TRIGGER trg_block_self_application BEFORE INSERT ON public.applications FOR EACH ROW EXECUTE FUNCTION fn_block_self_application();

CREATE TRIGGER trg_engagement_applications AFTER INSERT OR DELETE ON public.applications FOR EACH ROW EXECUTE FUNCTION fn_touch_post_engagement('post_id');

CREATE TRIGGER trg_moderation_enforce_applications BEFORE INSERT ON public.applications FOR EACH ROW EXECUTE FUNCTION fn_moderation_enforce('apply', 'applicant_user_id');

CREATE TRIGGER trg_chat_messages_undelete_guard BEFORE UPDATE OF deleted_for_everyone ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION fn_chat_messages_undelete_guard();

CREATE TRIGGER trg_increment_unread AFTER INSERT ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION increment_unread_count();

CREATE TRIGGER trg_moderation_enforce_chat_messages BEFORE INSERT ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION fn_moderation_enforce('message', 'sender_id');

CREATE TRIGGER trg_moderation_enforce_message_edits BEFORE UPDATE OF content ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION fn_moderation_enforce('message', 'sender_id');

CREATE TRIGGER trg_moderation_enforce_chat_preview BEFORE UPDATE OF last_message ON public.chats FOR EACH ROW EXECUTE FUNCTION fn_moderation_enforce('message', '');

CREATE TRIGGER trg_moderation_enforce_chats BEFORE INSERT ON public.chats FOR EACH ROW EXECUTE FUNCTION fn_moderation_enforce('message', '');

CREATE TRIGGER trg_dispute_decisions_immutable BEFORE DELETE OR UPDATE ON public.dispute_decisions FOR EACH ROW EXECUTE FUNCTION fn_block_decision_mutation();

CREATE TRIGGER trg_moderation_enforce_post_images BEFORE INSERT ON public.post_images FOR EACH ROW EXECUTE FUNCTION fn_moderation_enforce('post', '@post_author');

CREATE TRIGGER posts_reputation_recompute AFTER UPDATE OF status, selected_provider_id ON public.posts FOR EACH ROW EXECUTE FUNCTION trg_posts_reputation_recompute();

CREATE TRIGGER posts_validate_job_employment_trigger BEFORE INSERT OR UPDATE ON public.posts FOR EACH ROW EXECUTE FUNCTION posts_validate_job_employment_type();

CREATE TRIGGER trg_moderation_enforce_posts BEFORE INSERT OR UPDATE ON public.posts FOR EACH ROW EXECUTE FUNCTION fn_moderation_enforce('post', 'author_user_id');

CREATE TRIGGER trg_posts_moderation_guard BEFORE INSERT OR DELETE OR UPDATE ON public.posts FOR EACH ROW EXECUTE FUNCTION fn_posts_moderation_guard();

CREATE TRIGGER trg_engagement_saved_items AFTER INSERT OR DELETE ON public.saved_items FOR EACH ROW EXECUTE FUNCTION fn_touch_post_engagement('item_id');

CREATE TRIGGER trg_user_reports_guard BEFORE DELETE OR UPDATE ON public.user_reports FOR EACH ROW EXECUTE FUNCTION fn_user_reports_guard();

CREATE TRIGGER trg_user_reports_no_truncate BEFORE TRUNCATE ON public.user_reports FOR EACH STATEMENT EXECUTE FUNCTION fn_moderation_history_immutable();

CREATE TRIGGER trg_user_reports_prepare BEFORE INSERT ON public.user_reports FOR EACH ROW EXECUTE FUNCTION fn_user_reports_prepare();

CREATE TRIGGER trg_users_guard_privileged_columns BEFORE INSERT OR UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION fn_users_guard_privileged_columns();

CREATE TRIGGER trg_users_is_banned_guard BEFORE UPDATE OF is_banned ON public.users FOR EACH ROW EXECUTE FUNCTION fn_users_is_banned_guard();

CREATE TRIGGER trg_users_name_change_guard BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION fn_users_name_change_guard();

-- ── RLS ──

ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.applications ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.chats ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.dispute_decisions ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.disputes ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.escrow ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.fcm_tokens ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.job_completions ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.post_engagement ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.post_images ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.provider_reputation ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.saved_items ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.settlements ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.user_auth_identities ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.user_reports ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- ── Policies ──

CREATE POLICY admin_users_service_role ON public.admin_users AS PERMISSIVE FOR ALL TO public USING (true) WITH CHECK (true);

CREATE POLICY applications_insert ON public.applications AS PERMISSIVE FOR INSERT TO public WITH CHECK (true);

CREATE POLICY applications_select ON public.applications AS PERMISSIVE FOR SELECT TO public USING (true);

CREATE POLICY categories_read ON public.categories AS PERMISSIVE FOR SELECT TO anon, authenticated USING (active);

CREATE POLICY chat_messages_participant ON public.chat_messages AS PERMISSIVE FOR ALL TO authenticated USING ((EXISTS ( SELECT 1
   FROM chats c
  WHERE ((c.id = chat_messages.chat_id) AND (((auth.jwt() ->> 'user_id'::text) = c.user1) OR ((auth.jwt() ->> 'user_id'::text) = c.user2)))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM chats c
  WHERE ((c.id = chat_messages.chat_id) AND (((auth.jwt() ->> 'user_id'::text) = c.user1) OR ((auth.jwt() ->> 'user_id'::text) = c.user2))))));

CREATE POLICY chats_participant ON public.chats AS PERMISSIVE FOR ALL TO authenticated USING ((((auth.jwt() ->> 'user_id'::text) = user1) OR ((auth.jwt() ->> 'user_id'::text) = user2))) WITH CHECK ((((auth.jwt() ->> 'user_id'::text) = user1) OR ((auth.jwt() ->> 'user_id'::text) = user2)));

CREATE POLICY dispute_decisions_service_role ON public.dispute_decisions AS PERMISSIVE FOR ALL TO public USING (true) WITH CHECK (true);

CREATE POLICY disputes_service_role ON public.disputes AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY escrow_read_own ON public.escrow AS PERMISSIVE FOR SELECT TO public USING (((auth.jwt() ->> 'user_id'::text) IS NOT NULL));

CREATE POLICY escrow_service_role ON public.escrow AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY fcm_tokens_anon ON public.fcm_tokens AS PERMISSIVE FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY fcm_tokens_owner_all ON public.fcm_tokens AS PERMISSIVE FOR ALL TO authenticated USING ((user_id = (auth.jwt() ->> 'user_id'::text))) WITH CHECK ((user_id = (auth.jwt() ->> 'user_id'::text)));

CREATE POLICY fcm_tokens_service_role ON public.fcm_tokens AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY job_completions_service_role ON public.job_completions AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY notifications_anon_read ON public.notifications AS PERMISSIVE FOR SELECT TO anon USING (true);

CREATE POLICY notifications_anon_update ON public.notifications AS PERMISSIVE FOR UPDATE TO anon USING (true) WITH CHECK (true);

CREATE POLICY notifications_owner_read ON public.notifications AS PERMISSIVE FOR SELECT TO authenticated USING ((user_id = (auth.jwt() ->> 'user_id'::text)));

CREATE POLICY notifications_owner_update ON public.notifications AS PERMISSIVE FOR UPDATE TO authenticated USING ((user_id = (auth.jwt() ->> 'user_id'::text))) WITH CHECK ((user_id = (auth.jwt() ->> 'user_id'::text)));

CREATE POLICY notifications_service_role ON public.notifications AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY post_engagement_service_role ON public.post_engagement AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY post_images_delete ON public.post_images AS PERMISSIVE FOR DELETE TO public USING (true);

CREATE POLICY post_images_insert ON public.post_images AS PERMISSIVE FOR INSERT TO public WITH CHECK (true);

CREATE POLICY post_images_select ON public.post_images AS PERMISSIVE FOR SELECT TO public USING (true);

CREATE POLICY posts_delete_owner ON public.posts AS PERMISSIVE FOR DELETE TO authenticated USING ((author_user_id = (auth.jwt() ->> 'user_id'::text)));

CREATE POLICY posts_insert ON public.posts AS PERMISSIVE FOR INSERT TO public WITH CHECK (true);

CREATE POLICY posts_select ON public.posts AS PERMISSIVE FOR SELECT TO public USING (true);

CREATE POLICY posts_update_owner ON public.posts AS PERMISSIVE FOR UPDATE TO authenticated USING ((author_user_id = (auth.jwt() ->> 'user_id'::text))) WITH CHECK ((author_user_id = (auth.jwt() ->> 'user_id'::text)));

CREATE POLICY provider_reputation_service_role ON public.provider_reputation AS PERMISSIVE FOR ALL TO public USING (true) WITH CHECK (true);

CREATE POLICY reviews_service_role ON public.reviews AS PERMISSIVE FOR ALL TO public USING (true) WITH CHECK (true);

CREATE POLICY saved_items_owner ON public.saved_items AS PERMISSIVE FOR ALL TO authenticated USING ((user_id = (auth.jwt() ->> 'user_id'::text))) WITH CHECK ((user_id = (auth.jwt() ->> 'user_id'::text)));

CREATE POLICY saved_items_service_role ON public.saved_items AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY settlements_service_role ON public.settlements AS PERMISSIVE FOR ALL TO public USING (true) WITH CHECK (true);

CREATE POLICY transactions_read_own ON public.transactions AS PERMISSIVE FOR SELECT TO public USING (((auth.jwt() ->> 'user_id'::text) IS NOT NULL));

CREATE POLICY transactions_service_role ON public.transactions AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY user_reports_insert_own ON public.user_reports AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((reporter_id = (auth.jwt() ->> 'user_id'::text)));

CREATE POLICY user_reports_service_role ON public.user_reports AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY "Users are viewable by anon and authenticated" ON public.users AS PERMISSIVE FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY "Users insert by anon and authenticated" ON public.users AS PERMISSIVE FOR INSERT TO anon, authenticated WITH CHECK (true);

CREATE POLICY users_insert ON public.users AS PERMISSIVE FOR INSERT TO public WITH CHECK (true);

CREATE POLICY users_select ON public.users AS PERMISSIVE FOR SELECT TO public USING (true);

CREATE POLICY users_update_own ON public.users AS PERMISSIVE FOR UPDATE TO authenticated USING ((id = (auth.jwt() ->> 'user_id'::text))) WITH CHECK ((id = (auth.jwt() ->> 'user_id'::text)));

-- ── Grants (live) ──

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.admin_users TO service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.applications TO anon;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.applications TO authenticated;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.applications TO service_role;

GRANT SELECT ON public.categories TO anon;

GRANT SELECT ON public.categories TO authenticated;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.categories TO service_role;

GRANT INSERT, SELECT, UPDATE ON public.chat_messages TO authenticated;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.chat_messages TO service_role;

GRANT INSERT, SELECT, UPDATE ON public.chats TO authenticated;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.chats TO service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.dispute_decisions TO service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.disputes TO service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.escrow TO service_role;

GRANT DELETE, INSERT, SELECT, UPDATE ON public.fcm_tokens TO authenticated;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.fcm_tokens TO service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.job_completions TO service_role;

GRANT SELECT, UPDATE ON public.notifications TO anon;

GRANT SELECT, UPDATE ON public.notifications TO authenticated;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.notifications TO service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.post_engagement TO service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.post_images TO anon;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.post_images TO authenticated;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.post_images TO service_role;

GRANT INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE ON public.posts TO anon;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.posts TO authenticated;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.posts TO service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.provider_reputation TO service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.reviews TO service_role;

GRANT DELETE, INSERT, SELECT ON public.saved_items TO authenticated;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.saved_items TO service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.settlements TO service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.transactions TO service_role;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.user_auth_identities TO service_role;

GRANT INSERT ON public.user_reports TO authenticated;

GRANT INSERT, SELECT ON public.user_reports TO service_role;

GRANT INSERT, REFERENCES, SELECT, TRIGGER ON public.users TO anon;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.users TO authenticated;

GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.users TO service_role;
