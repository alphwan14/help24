-- =============================================================================
-- Migration 070 — Smart Posting SP-1: server-side category registry
-- =============================================================================
-- Replaces the hardcoded Dart list (Category.all) as the source of truth for
-- categories, and carries each category's question_schema (JSONB) that drives
-- the metadata-driven posting wizard. Adding a future category or question is
-- a DB row change — zero app code.
--
-- SAFE + ADDITIVE: creates one new read-only table and seeds it. Nothing else
-- changes. `name` values are BYTE-IDENTICAL to Category.all so every existing
-- feed/filter/admin query on posts.category keeps working unchanged.
--
-- Numbering note: 063–069 are reserved for the security track (users PII
-- lockdown etc.); 070+ is the product-schema block.
--
-- Clients: SELECT only (anon + authenticated). Writes: service_role only.
-- Rollback: DROP TABLE public.categories;
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.categories (
  id              TEXT PRIMARY KEY,          -- stable slug; never rename
  name            TEXT NOT NULL UNIQUE,      -- display name; byte-identical to Category.all
  icon            TEXT,                      -- icon key understood by the app (Material name)
  sort            INT  NOT NULL DEFAULT 100,
  active          BOOLEAN NOT NULL DEFAULT TRUE,
  question_schema JSONB,                     -- NULL = no questions (generic form)
  schema_version  INT  NOT NULL DEFAULT 1,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT categories_schema_is_object
    CHECK (question_schema IS NULL OR jsonb_typeof(question_schema) = 'object')
);

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS categories_read ON public.categories;
CREATE POLICY categories_read ON public.categories
  FOR SELECT TO anon, authenticated
  USING (active);

GRANT SELECT ON public.categories TO anon, authenticated;
-- No INSERT/UPDATE/DELETE grants: only the backend (service_role) manages rows.

-- ── Seed: exactly the current Category.all list (names byte-identical) ───────
-- ON CONFLICT DO NOTHING so re-running never clobbers later admin edits.
INSERT INTO public.categories (id, name, icon, sort) VALUES
  -- Home & Property
  ('plumbing',             'Plumbing',             'plumbing',              10),
  ('electrical',           'Electrical',           'electrical_services',   20),
  ('masonry',              'Masonry',              'foundation',            30),
  ('carpentry',            'Carpentry',            'handyman',              40),
  ('painting',             'Painting',             'format_paint',          50),
  ('welding',              'Welding',              'construction',          60),
  -- Cleaning & Household
  ('house-cleaning',       'House Cleaning',       'cleaning_services',     70),
  ('laundry',              'Laundry',              'local_laundry_service', 80),
  ('gardening',            'Gardening',            'grass',                 90),
  -- Security & Transport
  ('security-guard',       'Security Guard',       'security',             100),
  ('driver',               'Driver',               'directions_car',       110),
  ('delivery-rider',       'Delivery Rider',       'delivery_dining',      120),
  -- Automotive
  ('mechanic',             'Mechanic',             'car_repair',           130),
  ('car-wash',             'Car Wash',             'local_car_wash',       140),
  -- Appliance & Tech Repair
  ('appliance-repair',     'Appliance Repair',     'kitchen',              150),
  ('ac-repair',            'AC Repair',            'ac_unit',              160),
  ('phone-repair',         'Phone Repair',         'phone_android',        170),
  ('computer-repair',      'Computer Repair',      'computer',             180),
  -- Creative & Digital
  ('graphic-design',       'Graphic Design',       'brush',                190),
  ('software-development', 'Software Development', 'code',                 200),
  ('photography',          'Photography',          'camera_alt',           210),
  ('videography',          'Videography',          'videocam',             220),
  -- Events & Hospitality
  ('event-planning',       'Event Planning',       'celebration',          230),
  ('catering',             'Catering',             'restaurant',           240),
  -- Education & Care
  ('tutoring',             'Tutoring',             'school',               250),
  ('babysitting',          'Babysitting',          'child_care',           260),
  ('caregiving',           'Caregiving',           'favorite',             270),
  -- Moving & Construction
  ('moving-services',      'Moving Services',      'move_up',              280),
  ('interior-design',      'Interior Design',      'chair',                290),
  ('construction',         'Construction',         'architecture',         300),
  ('general-labour',       'General Labour',       'engineering',          310),
  -- Fallback
  ('other',                'Other',                'more_horiz',           999)
ON CONFLICT (id) DO NOTHING;
