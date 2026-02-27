-- =============================================================================
-- Chat messages: attachment_url for image/file messages.
-- =============================================================================

ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS attachment_url text;
COMMENT ON COLUMN public.chat_messages.attachment_url IS 'Public URL for image or file attachment (e.g. Supabase Storage).';
