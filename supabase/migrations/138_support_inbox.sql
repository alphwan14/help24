-- =============================================================================
-- Migration 138: the support Inbox — conversations between members and Help24
-- =============================================================================
-- ADDITIVE. Two new tables, nothing written at apply time.
--
-- Until now a member could reach Help24 only by emailing support@help24.co.ke,
-- which Cloudflare forwarded to one person's mailbox: no shared history, no
-- record of who answered, and nothing the dashboard could see. From now on
-- mail to support@ and info@ reaches the backend (a Cloudflare Email Worker,
-- workers/help24-mail) and lands here as a conversation; staff answer from the
-- dashboard's Inbox, and the answer goes back by email from support@, signed
-- "Help24 Support".
--
-- One conversation per thread, whatever the channel. Phase 1 is email; the
-- in-app support screen (phase 2) writes 'app' messages into the same tables,
-- which is why `channel` already allows it.
--
-- A reply finds its thread by, in order: the reference in its subject
-- ("[H24-7K3QXP]") from the same sender, the standard In-Reply-To/References
-- headers against messages stored here, or the same sender's latest open
-- conversation on the same subject within 14 days (backend support-rules.ts).
--
-- Service role only (the backend and the dashboard's server). No policies:
-- anon and authenticated get nothing. Phase 2 adds a member's read of their
-- own non-internal messages.
--
-- Rollback: DROP TABLE IF EXISTS public.support_messages;
--           DROP TABLE IF EXISTS public.support_conversations;
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.support_conversations (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Shown to the member in the subject line, and how their reply finds this thread.
  ref              text        NOT NULL UNIQUE CHECK (ref ~ '^H24-[A-HJ-NP-Z2-9]{6}$'),
  -- 'support' (support@) or 'general' (info@).
  label            text        NOT NULL CHECK (label IN ('support', 'general')),
  -- open: waiting on Help24 · waiting: waiting on the member · closed.
  status           text        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'waiting', 'closed')),
  subject          text        NOT NULL CHECK (char_length(subject) BETWEEN 1 AND 200),
  -- Where replies go. Lower-cased by the backend.
  contact_email    text        NOT NULL CHECK (contact_email = lower(contact_email) AND contact_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  contact_name     text        CHECK (contact_name IS NULL OR char_length(contact_name) <= 120),
  -- The member whose account uses contact_email, when there is one. Display only:
  -- an email's From line can be forged, so nothing is granted because of it.
  user_id          text        REFERENCES public.users (id) ON DELETE SET NULL,
  started_by       text        NOT NULL CHECK (started_by IN ('member', 'staff')),
  last_message_at  timestamptz NOT NULL DEFAULT now(),
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_support_conversations_status ON public.support_conversations (status, last_message_at DESC);
CREATE INDEX IF NOT EXISTS idx_support_conversations_contact ON public.support_conversations (contact_email, last_message_at DESC);
CREATE INDEX IF NOT EXISTS idx_support_conversations_user ON public.support_conversations (user_id) WHERE user_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.support_messages (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id   uuid        NOT NULL REFERENCES public.support_conversations (id) ON DELETE CASCADE,
  author            text        NOT NULL CHECK (author IN ('member', 'staff')),
  -- Which admin wrote a staff message. Never shown to the member, who sees
  -- "Help24 Support".
  admin_id          uuid        REFERENCES public.admin_users (id) ON DELETE SET NULL,
  -- An internal note: staff only, never sent.
  internal          boolean     NOT NULL DEFAULT false,
  channel           text        NOT NULL CHECK (channel IN ('email', 'app', 'note')),
  -- The message itself; for an email, the new text without the quoted history.
  body              text        NOT NULL CHECK (char_length(body) BETWEEN 1 AND 20000),
  -- The whole email as received, when trimming removed something.
  full_body         text        CHECK (full_body IS NULL OR char_length(full_body) <= 60000),
  -- RFC 5322 Message-ID, inbound or ours: threading, and a delivered-twice guard.
  email_message_id  text        UNIQUE,
  -- Inbound: the receiving server's SPF/DKIM/DMARC verdict for the From domain
  -- (null = no verdict available). Shown in the Inbox next to the sender.
  sender_verified   boolean,
  attachment_count  integer     NOT NULL DEFAULT 0 CHECK (attachment_count >= 0),
  -- Outbound email: sending → sent | failed.
  delivery          text        CHECK (delivery IS NULL OR delivery IN ('sending', 'sent', 'failed')),
  delivery_error    text        CHECK (delivery_error IS NULL OR char_length(delivery_error) <= 500),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (internal = (channel = 'note')),
  CHECK (NOT internal OR author = 'staff')
);

CREATE INDEX IF NOT EXISTS idx_support_messages_conversation ON public.support_messages (conversation_id, created_at);

ALTER TABLE public.support_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.support_conversations, public.support_messages FROM anon, authenticated;

COMMENT ON TABLE public.support_conversations IS
  'Support Inbox threads (migration 138): mail to support@/info@ and staff replies. Service role only.';
COMMENT ON TABLE public.support_messages IS
  'Messages in a support thread (migration 138). internal = staff note, never sent.';
