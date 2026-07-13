-- =============================================================================
-- Migration 073 — Posting Redesign R-2: provider-voiced questions (7 pilots)
-- =============================================================================
-- The 072 schemas were requester-voiced ("What do you need help with?") and
-- applied to every post type — wrong voice for a provider advertising a
-- service. This migration, per pilot category:
--   1. scopes the existing requester-voiced steps to applies_to
--      ["request","job"]  (jobs keep today's behavior until R-3 refines them),
--   2. appends OFFER-voiced steps (services offered, experience, …) with
--      applies_to ["offer"],
--   3. bumps version/schema_version to 2 (old posts keep their pinned
--      attributes_schema_version = 1 and stay interpretable).
--
-- SAFE: pure UPDATEs of categories.question_schema (data, not schema).
-- SUPERSEDES 072's content — do not re-run 072 after this (it would reset the
-- schemas to requester-only; re-run 073 instead to restore canon).
-- Rollback: re-run migration 072.
-- =============================================================================

-- ── Computer Repair ──────────────────────────────────────────────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 2,
  "steps": [
    {"key": "issue", "question": "What needs fixing?", "type": "select", "required": true, "highlight": true,
     "applies_to": ["request", "job"],
     "options": [
       {"value": "screen",        "label": "Screen"},
       {"value": "keyboard",      "label": "Keyboard"},
       {"value": "charging",      "label": "Battery / Charging"},
       {"value": "wont_power_on", "label": "Won't power on"},
       {"value": "software",      "label": "Slow / Software"},
       {"value": "other",         "label": "Other"}
     ]},
    {"key": "screen_cracked", "question": "Is the screen cracked?", "type": "boolean",
     "applies_to": ["request", "job"],
     "show_if": {"field": "issue", "any_of": ["screen"]}, "skip_in_emergency": true},
    {"key": "boots", "question": "Can it still boot?", "type": "boolean",
     "applies_to": ["request", "job"],
     "show_if": {"field": "issue", "any_of": ["software"]}, "skip_in_emergency": true},
    {"key": "brand", "question": "What brand is it?", "type": "select", "highlight": true,
     "applies_to": ["request", "job"],
     "options": [
       {"value": "hp", "label": "HP"}, {"value": "dell", "label": "Dell"},
       {"value": "lenovo", "label": "Lenovo"}, {"value": "apple", "label": "Apple"},
       {"value": "acer", "label": "Acer"}, {"value": "asus", "label": "Asus"},
       {"value": "other", "label": "Other"}
     ]},
    {"key": "warranty", "question": "Is it under warranty?", "type": "boolean", "skip_in_emergency": true,
     "applies_to": ["request", "job"]},
    {"key": "services", "question": "What repairs do you offer?", "type": "multiselect", "required": true, "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "screen_replacement", "label": "Screen replacement"},
       {"value": "hardware",           "label": "Hardware repairs"},
       {"value": "software_os",        "label": "Software / OS"},
       {"value": "data_recovery",      "label": "Data recovery"},
       {"value": "upgrades",           "label": "Upgrades (RAM/SSD)"}
     ]},
    {"key": "experience", "question": "How long have you been doing this?", "type": "select", "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "under_1", "label": "Under a year"}, {"value": "1_3", "label": "1–3 years"},
       {"value": "3_5", "label": "3–5 years"}, {"value": "5_plus", "label": "5+ years"}
     ]}
  ]
}
$json$::jsonb, schema_version = 2, updated_at = NOW()
WHERE id = 'computer-repair';

-- ── Phone Repair ─────────────────────────────────────────────────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 2,
  "steps": [
    {"key": "issue", "question": "What's wrong with the phone?", "type": "select", "required": true, "highlight": true,
     "applies_to": ["request", "job"],
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
     "applies_to": ["request", "job"],
     "show_if": {"field": "issue", "any_of": ["water_damage", "software"]}},
    {"key": "brand", "question": "What brand is it?", "type": "select", "highlight": true,
     "applies_to": ["request", "job"],
     "options": [
       {"value": "samsung", "label": "Samsung"}, {"value": "tecno", "label": "Tecno"},
       {"value": "infinix", "label": "Infinix"}, {"value": "iphone", "label": "iPhone"},
       {"value": "oppo", "label": "Oppo"}, {"value": "xiaomi", "label": "Xiaomi"},
       {"value": "other", "label": "Other"}
     ]},
    {"key": "services", "question": "What repairs do you offer?", "type": "multiselect", "required": true, "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "screens",       "label": "Screens"},
       {"value": "batteries",     "label": "Batteries"},
       {"value": "charging_port", "label": "Charging ports"},
       {"value": "water_damage",  "label": "Water damage"},
       {"value": "software",      "label": "Software / unlocking"}
     ]},
    {"key": "experience", "question": "How long have you been doing this?", "type": "select", "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "under_1", "label": "Under a year"}, {"value": "1_3", "label": "1–3 years"},
       {"value": "3_5", "label": "3–5 years"}, {"value": "5_plus", "label": "5+ years"}
     ]}
  ]
}
$json$::jsonb, schema_version = 2, updated_at = NOW()
WHERE id = 'phone-repair';

-- ── Plumbing ─────────────────────────────────────────────────────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 2,
  "steps": [
    {"key": "need", "question": "What do you need help with?", "type": "select", "required": true, "highlight": true,
     "applies_to": ["request", "job"],
     "options": [
       {"value": "leak",           "label": "Leak"},
       {"value": "installation",   "label": "Installation"},
       {"value": "blocked_drain",  "label": "Blocked drain"},
       {"value": "water_pressure", "label": "Water pressure"},
       {"value": "burst_pipe",     "label": "Burst pipe (emergency)"}
     ]},
    {"key": "water_off", "question": "Is the water shut off?", "type": "boolean",
     "applies_to": ["request", "job"],
     "show_if": {"field": "need", "any_of": ["leak", "burst_pipe"]}},
    {"key": "fixture", "question": "Where is the problem?", "type": "select", "highlight": true,
     "applies_to": ["request", "job"],
     "show_if": {"field": "need", "any_of": ["leak", "installation", "blocked_drain"]},
     "options": [
       {"value": "sink",         "label": "Sink"}, {"value": "toilet", "label": "Toilet"},
       {"value": "shower",       "label": "Shower"}, {"value": "pipes", "label": "Pipes"},
       {"value": "water_heater", "label": "Water heater"}, {"value": "other", "label": "Other"}
     ]},
    {"key": "setting", "question": "Indoor or outdoor?", "type": "select", "skip_in_emergency": true,
     "applies_to": ["request", "job"],
     "options": [
       {"value": "indoor", "label": "Indoor"}, {"value": "outdoor", "label": "Outdoor"},
       {"value": "both", "label": "Both"}
     ]},
    {"key": "services", "question": "What services do you offer?", "type": "multiselect", "required": true, "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "leak_repair",   "label": "Leak repairs"},
       {"value": "installation",  "label": "Installations"},
       {"value": "drains",        "label": "Drain unblocking"},
       {"value": "water_heaters", "label": "Water heaters"},
       {"value": "general",       "label": "General plumbing"}
     ]},
    {"key": "experience", "question": "How long have you been doing this?", "type": "select", "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "under_1", "label": "Under a year"}, {"value": "1_3", "label": "1–3 years"},
       {"value": "3_5", "label": "3–5 years"}, {"value": "5_plus", "label": "5+ years"}
     ]}
  ]
}
$json$::jsonb, schema_version = 2, updated_at = NOW()
WHERE id = 'plumbing';

-- ── Electrical ───────────────────────────────────────────────────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 2,
  "steps": [
    {"key": "need", "question": "What do you need help with?", "type": "select", "required": true, "highlight": true,
     "applies_to": ["request", "job"],
     "options": [
       {"value": "no_power",     "label": "No power"},
       {"value": "wiring",       "label": "Wiring"},
       {"value": "appliance",    "label": "Appliance installation"},
       {"value": "sockets",      "label": "Sockets / switches"},
       {"value": "lighting",     "label": "Lighting"},
       {"value": "other",        "label": "Other"}
     ]},
    {"key": "outage_scope", "question": "Is the whole place without power?", "type": "boolean",
     "applies_to": ["request", "job"],
     "show_if": {"field": "need", "any_of": ["no_power"]}},
    {"key": "scope", "question": "How big is the job?", "type": "select", "skip_in_emergency": true,
     "applies_to": ["request", "job"],
     "show_if": {"field": "need", "any_of": ["wiring", "sockets", "lighting"]},
     "options": [
       {"value": "single_item",    "label": "A single item"},
       {"value": "one_room",       "label": "One room"},
       {"value": "whole_property", "label": "Whole property"}
     ]},
    {"key": "services", "question": "What services do you offer?", "type": "multiselect", "required": true, "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "wiring",       "label": "Wiring"},
       {"value": "repairs",      "label": "Repairs / faults"},
       {"value": "appliances",   "label": "Appliance installation"},
       {"value": "lighting",     "label": "Lighting"},
       {"value": "solar",        "label": "Solar installation"}
     ]},
    {"key": "experience", "question": "How long have you been doing this?", "type": "select", "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "under_1", "label": "Under a year"}, {"value": "1_3", "label": "1–3 years"},
       {"value": "3_5", "label": "3–5 years"}, {"value": "5_plus", "label": "5+ years"}
     ]}
  ]
}
$json$::jsonb, schema_version = 2, updated_at = NOW()
WHERE id = 'electrical';

-- ── Tutoring ─────────────────────────────────────────────────────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 2,
  "steps": [
    {"key": "subject", "question": "What subject?", "type": "select", "required": true, "highlight": true,
     "applies_to": ["request", "job"],
     "options": [
       {"value": "math",      "label": "Mathematics"}, {"value": "sciences", "label": "Sciences"},
       {"value": "languages", "label": "Languages"},   {"value": "computer", "label": "Computer skills"},
       {"value": "music",     "label": "Music"},       {"value": "exam_prep", "label": "Exam prep"},
       {"value": "other",     "label": "Other"}
     ]},
    {"key": "level", "question": "What level?", "type": "select", "required": true, "highlight": true,
     "applies_to": ["request", "job"],
     "options": [
       {"value": "primary",     "label": "Primary"}, {"value": "high_school", "label": "High school"},
       {"value": "college",     "label": "College / University"}, {"value": "adult", "label": "Adult learner"}
     ]},
    {"key": "mode", "question": "Online or in person?", "type": "select", "required": true,
     "applies_to": ["request", "job"],
     "options": [
       {"value": "online",    "label": "Online"}, {"value": "in_person", "label": "In person"},
       {"value": "either",    "label": "Either"}
     ]},
    {"key": "schedule", "question": "Preferred schedule?", "type": "select", "skip_in_emergency": true,
     "applies_to": ["request", "job"],
     "options": [
       {"value": "weekdays", "label": "Weekdays"}, {"value": "weekends", "label": "Weekends"},
       {"value": "evenings", "label": "Evenings"}, {"value": "flexible", "label": "Flexible"}
     ]},
    {"key": "subjects_offered", "question": "What subjects do you teach?", "type": "multiselect", "required": true, "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "math",      "label": "Mathematics"}, {"value": "sciences", "label": "Sciences"},
       {"value": "languages", "label": "Languages"},   {"value": "computer", "label": "Computer skills"},
       {"value": "music",     "label": "Music"},       {"value": "exam_prep", "label": "Exam prep"}
     ]},
    {"key": "levels_offered", "question": "What levels do you teach?", "type": "multiselect", "required": true, "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "primary",     "label": "Primary"}, {"value": "high_school", "label": "High school"},
       {"value": "college",     "label": "College / University"}, {"value": "adult", "label": "Adult learners"}
     ]},
    {"key": "mode_offered", "question": "How do you teach?", "type": "select",
     "applies_to": ["offer"],
     "options": [
       {"value": "online",    "label": "Online"}, {"value": "in_person", "label": "In person"},
       {"value": "either",    "label": "Both"}
     ]}
  ]
}
$json$::jsonb, schema_version = 2, updated_at = NOW()
WHERE id = 'tutoring';

-- ── House Cleaning ───────────────────────────────────────────────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 2,
  "steps": [
    {"key": "property", "question": "What kind of place?", "type": "select", "required": true, "highlight": true,
     "applies_to": ["request", "job"],
     "options": [
       {"value": "house",     "label": "House"}, {"value": "apartment", "label": "Apartment"},
       {"value": "office",    "label": "Office"}
     ]},
    {"key": "bedrooms", "question": "How many bedrooms?", "type": "select", "highlight": true,
     "applies_to": ["request", "job"],
     "show_if": {"field": "property", "any_of": ["house", "apartment"]},
     "options": [
       {"value": "1", "label": "1"}, {"value": "2", "label": "2"},
       {"value": "3", "label": "3"}, {"value": "4_plus", "label": "4+"}
     ]},
    {"key": "frequency", "question": "One-time or recurring?", "type": "select", "required": true,
     "applies_to": ["request", "job"],
     "options": [
       {"value": "one_time", "label": "One-time"}, {"value": "weekly", "label": "Weekly"},
       {"value": "biweekly", "label": "Every two weeks"}, {"value": "monthly", "label": "Monthly"}
     ]},
    {"key": "extras", "question": "Anything extra?", "type": "multiselect", "skip_in_emergency": true,
     "applies_to": ["request", "job"],
     "options": [
       {"value": "laundry",  "label": "Laundry"}, {"value": "windows", "label": "Windows"},
       {"value": "deep_clean", "label": "Deep clean"}, {"value": "move_out", "label": "Move-out clean"}
     ]},
    {"key": "services", "question": "What cleaning do you offer?", "type": "multiselect", "required": true, "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "homes",      "label": "Homes"},
       {"value": "offices",    "label": "Offices"},
       {"value": "deep_clean", "label": "Deep cleaning"},
       {"value": "move_out",   "label": "Move-out cleaning"},
       {"value": "laundry",    "label": "Laundry"}
     ]},
    {"key": "experience", "question": "How long have you been doing this?", "type": "select", "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "under_1", "label": "Under a year"}, {"value": "1_3", "label": "1–3 years"},
       {"value": "3_5", "label": "3–5 years"}, {"value": "5_plus", "label": "5+ years"}
     ]}
  ]
}
$json$::jsonb, schema_version = 2, updated_at = NOW()
WHERE id = 'house-cleaning';

-- ── Mechanic ─────────────────────────────────────────────────────────────────
UPDATE public.categories SET question_schema = $json$
{
  "version": 2,
  "steps": [
    {"key": "issue", "question": "What's the problem?", "type": "select", "required": true, "highlight": true,
     "applies_to": ["request", "job"],
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
     "applies_to": ["request", "job"],
     "options": [
       {"value": "car",       "label": "Car"}, {"value": "motorbike", "label": "Motorbike"},
       {"value": "truck_van", "label": "Truck / Van"}, {"value": "matatu", "label": "Matatu"}
     ]},
    {"key": "drivable", "question": "Can it be driven?", "type": "boolean",
     "applies_to": ["request", "job"],
     "show_if": {"field": "issue", "any_of": ["breakdown", "brakes", "engine", "wont_start"]}},
    {"key": "towing", "question": "Do you need towing?", "type": "boolean",
     "applies_to": ["request", "job"],
     "show_if": {"field": "drivable", "any_of": ["false"]}},
    {"key": "services", "question": "What services do you offer?", "type": "multiselect", "required": true, "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "engine",   "label": "Engine work"},
       {"value": "brakes",   "label": "Brakes"},
       {"value": "electrical", "label": "Auto electrical"},
       {"value": "tyres",    "label": "Tyres"},
       {"value": "service",  "label": "Regular service"},
       {"value": "roadside", "label": "Roadside rescue"}
     ]},
    {"key": "vehicles", "question": "What vehicles do you work on?", "type": "multiselect", "required": true, "highlight": true,
     "applies_to": ["offer"],
     "options": [
       {"value": "cars",       "label": "Cars"}, {"value": "motorbikes", "label": "Motorbikes"},
       {"value": "trucks_vans", "label": "Trucks / Vans"}, {"value": "matatus", "label": "Matatus"}
     ]}
  ]
}
$json$::jsonb, schema_version = 2, updated_at = NOW()
WHERE id = 'mechanic';
