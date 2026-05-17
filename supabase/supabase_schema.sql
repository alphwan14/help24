-- ============================================
-- Help24 Supabase Database Schema
-- PRODUCTION-READY - SAFE TO RUN MULTIPLE TIMES
-- ============================================

-- Enable UUID extension (required for auto-generated IDs)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- DROP EXISTING POLICIES (Clean slate)
-- ============================================
DO $$ 
DECLARE
    pol RECORD;
BEGIN
    -- Drop all policies on our tables
    FOR pol IN 
        SELECT policyname, tablename 
        FROM pg_policies 
        WHERE schemaname = 'public' 
        AND tablename IN ('users', 'posts', 'post_images', 'messages', 'applications')
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON %I', pol.policyname, pol.tablename);
    END LOOP;
END $$;

-- ============================================
-- USERS TABLE (Firebase Auth Sync)
-- ============================================
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL,
    name TEXT,
    photo_url TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_login TIMESTAMPTZ DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- Users policies - ALLOW ALL for anonymous access
CREATE POLICY "users_select" ON users FOR SELECT USING (true);
CREATE POLICY "users_insert" ON users FOR INSERT WITH CHECK (true);
CREATE POLICY "users_update" ON users FOR UPDATE USING (true);

-- ============================================
-- POSTS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS posts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'Other',
    location TEXT NOT NULL DEFAULT 'Nairobi',
    urgency TEXT NOT NULL DEFAULT 'flexible',
    price DECIMAL(12, 2) NOT NULL DEFAULT 0,
    type TEXT NOT NULL DEFAULT 'request',
    difficulty TEXT DEFAULT 'medium',
    rating DECIMAL(2, 1) DEFAULT 4.5,
    author_name TEXT DEFAULT 'Anonymous',
    author_temp_id TEXT NOT NULL,
    author_user_id TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Drop the difficulty constraint if it exists (allows flexibility for jobs)
ALTER TABLE posts DROP CONSTRAINT IF EXISTS posts_difficulty_check;

-- Add constraints only if they don't exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'posts_urgency_check'
    ) THEN
        ALTER TABLE posts ADD CONSTRAINT posts_urgency_check 
            CHECK (urgency IN ('urgent', 'soon', 'flexible'));
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'posts_type_check'
    ) THEN
        ALTER TABLE posts ADD CONSTRAINT posts_type_check 
            CHECK (type IN ('request', 'offer', 'job'));
    END IF;
    
    -- Note: difficulty constraint removed to allow flexibility for job types
END $$;

-- Enable RLS
ALTER TABLE posts ENABLE ROW LEVEL SECURITY;

-- Posts policies - ALLOW ALL for now (no auth requirement)
CREATE POLICY "posts_select" ON posts FOR SELECT USING (true);
CREATE POLICY "posts_insert" ON posts FOR INSERT WITH CHECK (true);
CREATE POLICY "posts_update" ON posts FOR UPDATE USING (true);
CREATE POLICY "posts_delete" ON posts FOR DELETE USING (true);

-- ============================================
-- POST_IMAGES TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS post_images (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    post_id UUID REFERENCES posts(id) ON DELETE CASCADE,
    image_url TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE post_images ENABLE ROW LEVEL SECURITY;

-- Post images policies
CREATE POLICY "post_images_select" ON post_images FOR SELECT USING (true);
CREATE POLICY "post_images_insert" ON post_images FOR INSERT WITH CHECK (true);
CREATE POLICY "post_images_delete" ON post_images FOR DELETE USING (true);

-- ============================================
-- MESSAGES TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS messages (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    conversation_id TEXT NOT NULL,
    sender_temp_id TEXT NOT NULL,
    sender_user_id TEXT,
    receiver_temp_id TEXT NOT NULL,
    receiver_user_id TEXT,
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

-- Messages policies
CREATE POLICY "messages_select" ON messages FOR SELECT USING (true);
CREATE POLICY "messages_insert" ON messages FOR INSERT WITH CHECK (true);

-- ============================================
-- APPLICATIONS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS applications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    post_id UUID REFERENCES posts(id) ON DELETE CASCADE,
    applicant_name TEXT NOT NULL DEFAULT 'Anonymous',
    applicant_temp_id TEXT NOT NULL,
    applicant_user_id TEXT,
    message TEXT NOT NULL,
    proposed_price DECIMAL(12, 2) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE applications ENABLE ROW LEVEL SECURITY;

-- Applications policies
CREATE POLICY "applications_select" ON applications FOR SELECT USING (true);
CREATE POLICY "applications_insert" ON applications FOR INSERT WITH CHECK (true);

-- ============================================
-- CREATE INDEXES (Safe - uses IF NOT EXISTS logic)
-- ============================================
DO $$ 
BEGIN
    -- Users indexes
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_users_email') THEN
        CREATE INDEX idx_users_email ON users(email);
    END IF;
    
    -- Posts indexes
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_posts_category') THEN
        CREATE INDEX idx_posts_category ON posts(category);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_posts_type') THEN
        CREATE INDEX idx_posts_type ON posts(type);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_posts_created_at') THEN
        CREATE INDEX idx_posts_created_at ON posts(created_at DESC);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_posts_author_temp_id') THEN
        CREATE INDEX idx_posts_author_temp_id ON posts(author_temp_id);
    END IF;
    
    -- Post images indexes
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_post_images_post_id') THEN
        CREATE INDEX idx_post_images_post_id ON post_images(post_id);
    END IF;
    
    -- Messages indexes
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_messages_conversation_id') THEN
        CREATE INDEX idx_messages_conversation_id ON messages(conversation_id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_messages_created_at') THEN
        CREATE INDEX idx_messages_created_at ON messages(created_at DESC);
    END IF;
    
    -- Applications indexes
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_applications_post_id') THEN
        CREATE INDEX idx_applications_post_id ON applications(post_id);
    END IF;
END $$;

-- ============================================
-- GRANT PERMISSIONS (Critical for anon access)
-- ============================================
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated;

-- ============================================
-- ENABLE REALTIME (for messages)
-- ============================================
DO $$
BEGIN
    -- Check if publication exists and add table
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_publication_tables 
            WHERE pubname = 'supabase_realtime' AND tablename = 'messages'
        ) THEN
            ALTER PUBLICATION supabase_realtime ADD TABLE messages;
        END IF;
    END IF;
EXCEPTION WHEN OTHERS THEN
    -- Ignore errors
    NULL;
END $$;

-- ============================================
-- STORAGE SETUP (Run supabase_storage_setup.sql separately)
-- ============================================
-- 
-- For storage bucket policies, run the separate file:
-- supabase_storage_setup.sql
--
-- Or set up via Dashboard:
-- 1. Go to Storage > Create bucket "post-images"
-- 2. Enable "Public bucket" toggle
-- 3. That's it! Public buckets don't need additional policies
--
-- ============================================

-- ============================================
-- VERIFY DATABASE SETUP
-- ============================================
-- Run these queries to check everything works:

-- Check tables exist:
-- SELECT table_name FROM information_schema.tables WHERE table_schema = 'public';

-- Check policies:
-- SELECT schemaname, tablename, policyname FROM pg_policies WHERE schemaname = 'public';

-- Check post_images table:
-- SELECT * FROM post_images LIMIT 5;

-- Test posts with images query:
-- SELECT p.id, p.title, pi.image_url 
-- FROM posts p 
-- LEFT JOIN post_images pi ON p.id = pi.post_id 
-- LIMIT 5;

-- ============================================
-- SCHEMA COMPLETE
-- ============================================
