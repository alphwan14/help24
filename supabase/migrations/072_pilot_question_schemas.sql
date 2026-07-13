-- =============================================================================
-- Migration 072 — Smart Posting SP-2: pilot question schemas (7 categories)
-- =============================================================================
-- The guided-conversation definitions. The Flutter renderer is fully generic;
-- everything category-specific lives HERE. Editing a schema (or adding one for
-- a new category) requires no app release.
--
-- Schema contract (parsed by mobile-app/lib/models/category_schema.dart):
--   { "version": 1, "steps": [ {
--       "key":       stable snake_case answer key (append-only, never rename),
--       "question":  the single question shown on its own screen,
--       "type":      select | multiselect | boolean | text | number
--                    (unknown types are SKIPPED by the app — forward compatible),
--       "options":   [{"value","label"}]           (select/multiselect),
--       "required":  bool (default false),
--       "highlight": bool — surfaced on feed cards later (SP-3),
--       "applies_to":["request","job","offer"]     (default: all),
--       "skip_in_emergency": bool — hidden when urgency = urgent, so an
--                    emergency post finishes in seconds,
--       "show_if":   {"field": <other key>, "any_of": [values]} — progressive
--                    disclosure: only shown after the parent answer matches.
--                    Booleans match against "true"/"false".
--   } ] }
--
-- SAFE: pure UPDATEs of categories.question_schema. Re-running resets these
-- seven schemas to this canonical definition (intentional).
-- Rollback: UPDATE public.categories SET question_schema = NULL
--           WHERE id IN ('computer-repair','phone-repair','plumbing',
--                        'electrical','tutoring','house-cleaning','mechanic');
-- =============================================================================

-- ── Computer Repair ──────────────────────────────────────────────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 1,
  "steps": [
    {"key": "issue", "question": "What needs fixing?", "type": "select", "required": true, "highlight": true,
     "options": [
       {"value": "screen",        "label": "Screen"},
       {"value": "keyboard",      "label": "Keyboard"},
       {"value": "charging",      "label": "Battery / Charging"},
       {"value": "wont_power_on", "label": "Won't power on"},
       {"value": "software",      "label": "Slow / Software"},
       {"value": "other",         "label": "Other"}
     ]},
    {"key": "screen_cracked", "question": "Is the screen cracked?", "type": "boolean",
     "show_if": {"field": "issue", "any_of": ["screen"]}, "skip_in_emergency": true},
    {"key": "boots", "question": "Can it still boot?", "type": "boolean",
     "show_if": {"field": "issue", "any_of": ["software"]}, "skip_in_emergency": true},
    {"key": "brand", "question": "What brand is it?", "type": "select", "highlight": true,
     "options": [
       {"value": "hp", "label": "HP"}, {"value": "dell", "label": "Dell"},
       {"value": "lenovo", "label": "Lenovo"}, {"value": "apple", "label": "Apple"},
       {"value": "acer", "label": "Acer"}, {"value": "asus", "label": "Asus"},
       {"value": "other", "label": "Other"}
     ]},
    {"key": "warranty", "question": "Is it under warranty?", "type": "boolean", "skip_in_emergency": true}
  ]
}
$json$::jsonb, schema_version = 1, updated_at = NOW()
WHERE id = 'computer-repair';

-- ── Phone Repair ─────────────────────────────────────────────────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 1,
  "steps": [
    {"key": "issue", "question": "What's wrong with the phone?", "type": "select", "required": true, "highlight": true,
     "options": [
       {"value": "cracked_screen", "label": "Cracked screen"},
       {"value": "battery",        "label": "Battery"},
       {"value": "wont_power_on",  "label": "Won't power on"},
       {"value": "charging_port",  "label": "Charging port"},
       {"value": "water_damage",   "label": "Water damage"},
       {"value": "software",       "label": "Software"},
       {"value": "other",          "label": "Other"}
     ]},
    {"key": "powers_on", "question": "Does it still power on?", "type": "boolean",
     "show_if": {"field": "issue", "any_of": ["water_damage", "software"]}},
    {"key": "brand", "question": "What brand is it?", "type": "select", "highlight": true,
     "options": [
       {"value": "samsung", "label": "Samsung"}, {"value": "tecno", "label": "Tecno"},
       {"value": "infinix", "label": "Infinix"}, {"value": "iphone", "label": "iPhone"},
       {"value": "oppo", "label": "Oppo"}, {"value": "xiaomi", "label": "Xiaomi"},
       {"value": "other", "label": "Other"}
     ]}
  ]
}
$json$::jsonb, schema_version = 1, updated_at = NOW()
WHERE id = 'phone-repair';

-- ── Plumbing ─────────────────────────────────────────────────────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 1,
  "steps": [
    {"key": "need", "question": "What do you need help with?", "type": "select", "required": true, "highlight": true,
     "options": [
       {"value": "leak",           "label": "Leak"},
       {"value": "installation",   "label": "Installation"},
       {"value": "blocked_drain",  "label": "Blocked drain"},
       {"value": "water_pressure", "label": "Water pressure"},
       {"value": "burst_pipe",     "label": "Burst pipe (emergency)"}
     ]},
    {"key": "water_off", "question": "Is the water shut off?", "type": "boolean",
     "show_if": {"field": "need", "any_of": ["leak", "burst_pipe"]}},
    {"key": "fixture", "question": "Where is the problem?", "type": "select", "highlight": true,
     "show_if": {"field": "need", "any_of": ["leak", "installation", "blocked_drain"]},
     "options": [
       {"value": "sink",         "label": "Sink"}, {"value": "toilet", "label": "Toilet"},
       {"value": "shower",       "label": "Shower"}, {"value": "pipes", "label": "Pipes"},
       {"value": "water_heater", "label": "Water heater"}, {"value": "other", "label": "Other"}
     ]},
    {"key": "setting", "question": "Indoor or outdoor?", "type": "select", "skip_in_emergency": true,
     "options": [
       {"value": "indoor", "label": "Indoor"}, {"value": "outdoor", "label": "Outdoor"},
       {"value": "both", "label": "Both"}
     ]}
  ]
}
$json$::jsonb, schema_version = 1, updated_at = NOW()
WHERE id = 'plumbing';

-- ── Electrical ───────────────────────────────────────────────────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 1,
  "steps": [
    {"key": "need", "question": "What do you need help with?", "type": "select", "required": true, "highlight": true,
     "options": [
       {"value": "no_power",     "label": "No power"},
       {"value": "wiring",       "label": "Wiring"},
       {"value": "appliance",    "label": "Appliance installation"},
       {"value": "sockets",      "label": "Sockets / switches"},
       {"value": "lighting",     "label": "Lighting"},
       {"value": "other",        "label": "Other"}
     ]},
    {"key": "outage_scope", "question": "Is the whole place without power?", "type": "boolean",
     "show_if": {"field": "need", "any_of": ["no_power"]}},
    {"key": "scope", "question": "How big is the job?", "type": "select", "skip_in_emergency": true,
     "show_if": {"field": "need", "any_of": ["wiring", "sockets", "lighting"]},
     "options": [
       {"value": "single_item",    "label": "A single item"},
       {"value": "one_room",       "label": "One room"},
       {"value": "whole_property", "label": "Whole property"}
     ]}
  ]
}
$json$::jsonb, schema_version = 1, updated_at = NOW()
WHERE id = 'electrical';

-- ── Tutoring ─────────────────────────────────────────────────────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 1,
  "steps": [
    {"key": "subject", "question": "What subject?", "type": "select", "required": true, "highlight": true,
     "options": [
       {"value": "math",      "label": "Mathematics"}, {"value": "sciences", "label": "Sciences"},
       {"value": "languages", "label": "Languages"},   {"value": "computer", "label": "Computer skills"},
       {"value": "music",     "label": "Music"},       {"value": "exam_prep", "label": "Exam prep"},
       {"value": "other",     "label": "Other"}
     ]},
    {"key": "level", "question": "What level?", "type": "select", "required": true, "highlight": true,
     "options": [
       {"value": "primary",     "label": "Primary"}, {"value": "high_school", "label": "High school"},
       {"value": "college",     "label": "College / University"}, {"value": "adult", "label": "Adult learner"}
     ]},
    {"key": "mode", "question": "Online or in person?", "type": "select", "required": true,
     "options": [
       {"value": "online",    "label": "Online"}, {"value": "in_person", "label": "In person"},
       {"value": "either",    "label": "Either"}
     ]},
    {"key": "schedule", "question": "Preferred schedule?", "type": "select", "skip_in_emergency": true,
     "options": [
       {"value": "weekdays", "label": "Weekdays"}, {"value": "weekends", "label": "Weekends"},
       {"value": "evenings", "label": "Evenings"}, {"value": "flexible", "label": "Flexible"}
     ]}
  ]
}
$json$::jsonb, schema_version = 1, updated_at = NOW()
WHERE id = 'tutoring';

-- ── House Cleaning ───────────────────────────────────────────────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 1,
  "steps": [
    {"key": "property", "question": "What kind of place?", "type": "select", "required": true, "highlight": true,
     "options": [
       {"value": "house",     "label": "House"}, {"value": "apartment", "label": "Apartment"},
       {"value": "office",    "label": "Office"}
     ]},
    {"key": "bedrooms", "question": "How many bedrooms?", "type": "select", "highlight": true,
     "show_if": {"field": "property", "any_of": ["house", "apartment"]},
     "options": [
       {"value": "1", "label": "1"}, {"value": "2", "label": "2"},
       {"value": "3", "label": "3"}, {"value": "4_plus", "label": "4+"}
     ]},
    {"key": "frequency", "question": "One-time or recurring?", "type": "select", "required": true,
     "options": [
       {"value": "one_time", "label": "One-time"}, {"value": "weekly", "label": "Weekly"},
       {"value": "biweekly", "label": "Every two weeks"}, {"value": "monthly", "label": "Monthly"}
     ]},
    {"key": "extras", "question": "Anything extra?", "type": "multiselect", "skip_in_emergency": true,
     "options": [
       {"value": "laundry",  "label": "Laundry"}, {"value": "windows", "label": "Windows"},
       {"value": "deep_clean", "label": "Deep clean"}, {"value": "move_out", "label": "Move-out clean"}
     ]}
  ]
}
$json$::jsonb, schema_version = 1, updated_at = NOW()
WHERE id = 'house-cleaning';

-- ── Mechanic (demonstrates two-level progressive disclosure) ─────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 1,
  "steps": [
    {"key": "issue", "question": "What's the problem?", "type": "select", "required": true, "highlight": true,
     "options": [
       {"value": "wont_start", "label": "Won't start"},
       {"value": "breakdown",  "label": "Breakdown (roadside)"},
       {"value": "brakes",     "label": "Brakes"},
       {"value": "engine",     "label": "Engine"},
       {"value": "tyres",      "label": "Tyres"},
       {"value": "service",    "label": "Regular service"},
       {"value": "other",      "label": "Other"}
     ]},
    {"key": "vehicle", "question": "What vehicle?", "type": "select", "required": true, "highlight": true,
     "options": [
       {"value": "car",       "label": "Car"}, {"value": "motorbike", "label": "Motorbike"},
       {"value": "truck_van", "label": "Truck / Van"}, {"value": "matatu", "label": "Matatu"}
     ]},
    {"key": "drivable", "question": "Can it be driven?", "type": "boolean",
     "show_if": {"field": "issue", "any_of": ["breakdown", "brakes", "engine", "wont_start"]}},
    {"key": "towing", "question": "Do you need towing?", "type": "boolean",
     "show_if": {"field": "drivable", "any_of": ["false"]}}
  ]
}
$json$::jsonb, schema_version = 1, updated_at = NOW()
WHERE id = 'mechanic';
