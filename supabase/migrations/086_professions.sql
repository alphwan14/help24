-- =============================================================================
-- Migration 086 — Professional Profile PP-1: controlled profession vocabulary
-- =============================================================================
-- `users.profession` has been FREE TEXT since migration 012, which produced
-- "electrician", "Electrician", "Electrical", "Electrical Works" and "electric"
-- as five distinct values for one trade. Provider search, filtering,
-- recommendations, analytics and provider↔request matching all need exactly
-- one canonical value per trade.
--
-- This registry becomes that vocabulary. The column keeps its name and type —
-- it simply now holds `professions.id` (a stable slug) instead of prose.
--
-- SAFE + ADDITIVE. Creates ONE new read-only table and seeds it. It does not
-- touch `users`, does not migrate or destroy any existing profession value,
-- and adds no constraint to `users.profession`:
--   * Existing free text keeps rendering verbatim in the app (the client falls
--     back to the raw string when a value resolves to no row here), it simply
--     counts as an incomplete profile field until the user picks from the list.
--   * A FK / CHECK on users.profession is deliberately NOT added — it would
--     reject every legacy row on its next unrelated UPDATE and break existing
--     users. Validity is enforced at the write path (the app only ever writes
--     ids from this table).
--
-- The app ships a bundled copy of this seed, so the profession selector works
-- fully BEFORE this migration is applied, offline, and if the read fails —
-- same resilience contract as 070_categories.
--
-- Adding a profession later is ONE INSERT here. No app release.
--
-- Clients: SELECT only (anon + authenticated). Writes: service_role only.
-- Rollback: DROP TABLE public.professions;
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.professions (
  id          TEXT PRIMARY KEY,           -- stable slug stored in users.profession; NEVER rename
  name        TEXT NOT NULL UNIQUE,       -- display label
  icon        TEXT,                       -- icon key understood by the app (see utils/icon_keys.dart)
  sort        INT  NOT NULL DEFAULT 100,
  active      BOOLEAN NOT NULL DEFAULT TRUE,
  -- Optional link to public.categories(id). The seam for future provider↔request
  -- matching ("show Electricians for this Electrical request"). Intentionally NOT
  -- a foreign key: a profession may exist before/without a matching category, and
  -- a category rename must never block a profession insert.
  category_id TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.professions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS professions_read ON public.professions;
CREATE POLICY professions_read ON public.professions
  FOR SELECT TO anon, authenticated
  USING (active);

GRANT SELECT ON public.professions TO anon, authenticated;
-- No INSERT/UPDATE/DELETE grants: only the backend (service_role) manages rows.

CREATE INDEX IF NOT EXISTS idx_professions_sort ON public.professions (sort) WHERE active;

-- ── Seed ────────────────────────────────────────────────────────────────────
-- ids/names are BYTE-IDENTICAL to Profession.bundled in the app, so a client
-- running on the bundled fallback and a client reading this table resolve every
-- stored value the same way.
-- ON CONFLICT DO NOTHING so re-running never clobbers later admin edits.
INSERT INTO public.professions (id, name, icon, sort, category_id) VALUES
  ('electrician',     'Electrician',     'electrical_services',  10, 'electrical'),
  ('plumber',         'Plumber',         'plumbing',             20, 'plumbing'),
  ('mechanic',        'Mechanic',        'car_repair',           30, 'mechanic'),
  ('cleaner',         'Cleaner',         'cleaning_services',    40, 'house-cleaning'),
  ('tutor',           'Tutor',           'school',               50, 'tutoring'),
  ('driver',          'Driver',          'directions_car',       60, 'driver'),
  ('welder',          'Welder',          'construction',         70, 'welding'),
  ('builder',         'Builder',         'architecture',         80, 'construction'),
  ('painter',         'Painter',         'format_paint',         90, 'painting'),
  ('carpenter',       'Carpenter',       'handyman',            100, 'carpentry'),
  ('it-technician',   'IT Technician',   'computer',            110, 'computer-repair'),
  ('photographer',    'Photographer',    'camera_alt',          120, 'photography'),
  ('salon-beauty',    'Salon & Beauty',  'content_cut',         130, NULL),
  ('tailor',          'Tailor',          'checkroom',           140, NULL),
  ('cook',            'Cook',            'restaurant',          150, 'catering'),
  ('moving-services', 'Moving Services', 'move_up',             160, 'moving-services'),
  ('other',           'Other',           'more_horiz',          999, 'other')
ON CONFLICT (id) DO NOTHING;

COMMENT ON TABLE public.professions IS
  'Controlled profession vocabulary. users.profession holds professions.id. Add a trade with one INSERT — no app release.';
COMMENT ON COLUMN public.professions.category_id IS
  'Optional link to categories.id for future provider<->request matching. Not a FK by design.';
