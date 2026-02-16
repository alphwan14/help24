-- =============================================================================
-- RUN THIS IN SUPABASE SQL EDITOR (fix "permission denied for table conversations")
-- =============================================================================
-- Run this if you already ran 002_messaging.sql and get permission denied (42501).
-- This grants anon and authenticated roles access to the messaging tables.
-- =============================================================================

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.conversations TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.messages TO anon, authenticated;
