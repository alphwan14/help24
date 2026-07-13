# 🧠 Smart Posting System — Architecture Audit & Proposal

> Status: **SP-1 + SP-2 IMPLEMENTED (2026-07-12), awaiting device verification.** SP-3 (smart display) / SP-4 (filters) / SP-5 (server hardening) not started.
> Goal: category-aware posting — every category asks its own questions (Laptop Repair → brand/model/issue; Plumber → leak/emergency/indoor-outdoor; …), driven by metadata so new categories need **no code changes**.
>
> **Implemented artifacts:** migrations `070_categories.sql` / `071_post_attributes.sql` / `072_pilot_question_schemas.sql` (7 pilot categories); Flutter `models/category_schema.dart` (parser + progressive-disclosure resolver, 19 unit tests in `test/category_schema_test.dart`), `services/category_schema_service.dart` (fetch → 24h cache → bundled fallback), `widgets/schema_question_flow.dart` (generic one-question-at-a-time renderer with auto-advance + emergency mode); wizard integration in `post_screen.dart` (dynamic 4th step, snapshotted step count, pruned answers into `posts.attributes`). Design additions vs the original proposal: `show_if` conditional steps (progressive disclosure), `skip_in_emergency` (urgent posts finish in seconds), guided one-question-per-screen UX instead of a fields page.

---

## 1. AUDIT — how posting works today (verified facts)

### 1.1 The flow
- **One screen for everything:** `mobile-app/lib/screens/post_screen.dart` — a 3-step wizard (type selection → form → preview). Request / Offer / Job share **one identical form**; the only differences are the price label wording and a job-only Employment Type dropdown.
- **Fields asked today (all types):** title, description, category (dropdown), urgency (3 chips), pricing type, city (+optional area), price, images (≤5, ≤5MB each). Job adds employment type. `difficulty` exists in the DB but is **never asked** (always defaults `medium`) — precedent for a column without a form input.
- **Validation:** client-side non-empty checks only (`_canProceed()` at `post_screen.dart:945`). No min lengths, no price bounds. DB-level: CHECK constraints on `type`, `urgency`, `pricing_type`, `employment_type` (+ a trigger requiring employment_type when type='job' — migration 017), `status`.
- **Submission is a DIRECT Supabase insert from the app** (`post_service.dart:281` / `:375` for jobs) using the anon/publishable key. **The NestJS backend has no create-post endpoint** — it only mutates lifecycle state (select provider, approve, archive, disputes). The Next.js admin dashboard is a second direct reader.

### 1.2 The data model
- Table `public.posts` (created in `supabase/supabase_schema.sql:50`, altered by migrations 004/017/018/022/030/056): **entirely flat, typed columns.** Full list: id, title, description, category, location, urgency, price, type, difficulty, rating, author_name, author_temp_id, author_user_id, created_at, pricing_type, employment_type, is_urgent, latitude, longitude, urgent_expires_at, selected_provider_id, status, archived_at, archived_by.
- **No JSONB column. No subcategory. No metadata/attributes column. No categories table.**
- `category` is free-form `TEXT DEFAULT 'Other'`. Its source of truth is a **hardcoded Dart list** — `Category.all`, 31 entries + 'Other', in `mobile-app/lib/models/post_model.dart:44-87` (`{name, icon}` only). The filter sheet even allows free-text custom categories (`filter_bottom_sheet.dart:45`), so the category space is already open-ended on the read side.
- Child table `post_images` holds image URLs.

### 1.3 Consumers a dynamic-fields change touches
- **Write path (small):** `post_screen.dart`, `post_model.dart` (`toJson`), `post_service.dart`.
- **Read path (wider):** `post_card.dart` (feed card), `discover_screen.dart:_showPostDetails` (detail sheet), a near-duplicate `_PostDetailPage` in `messages_screen.dart:2814`, `job_card.dart`/`marketplace_card_components.dart`, `filter_bottom_sheet.dart`, and admin pages `admin-dashboard/app/dashboard/marketplace/*` + `insights/categories` (aggregates by `posts.category`).
- **Filters:** `PostFilters` (`post_service.dart:9`) uses `inFilter('category', […])`, ilike on location/title/description, eq on type/urgency/difficulty, price range. Backend never reads category/pricing fields.

### 1.4 Security posture (relevant constraint)
- `posts` is **anon-readable AND anon-writable** (permissive `USING(true)` policies; migration 061's header explicitly defers the posts lockdown). Client-side `isAuthor` is the only write gate today. Any Smart Posting validation placed **only** in Flutter has the same (existing) trust level; server-side enforcement is a separate, already-planned security step.

### 1.5 Key audit conclusions
1. Nothing is metadata-driven today — but nothing blocks it either: the schema is additive-friendly, and `category` strings pass through feeds/filters/admin untouched.
2. Because the app posts **directly to Supabase**, there is no server chokepoint to validate dynamic answers — MVP validation must live in the app + Postgres, with a backend endpoint as a later hardening phase.
3. The three post types differing only cosmetically means the wizard is already generic — we're adding a **category-question layer**, not rewriting the wizard.

---

## 2. ARCHITECTURE PROPOSAL — metadata-driven posting engine

### 2.1 Core idea
Three additive pieces, no rewrites:

```
categories (DB table)          posts.attributes (JSONB)         Dynamic renderer (Flutter)
  id (slug, stable)              {"brand":"HP",                   SchemaForm(schema) →
  name, icon, sort, active        "issue":"screen",                for each field:
  question_schema (JSONB) ───▶    "urgency_type":"emergency"}      select → chips
  schema_version                 + posts.schema_version            boolean → toggle
                                                                   number → numeric field
                                                                   text → text field
```

1. **`categories` table** — server-side registry replacing the hardcoded Dart list. Seeded from `Category.all` (name preserved **byte-identical** so every existing feed/filter/admin query keeps working). Each row carries a `question_schema` JSONB describing that category's questions.
2. **`posts.attributes JSONB NOT NULL DEFAULT '{}'`** — the answers, keyed by stable field keys, plus `posts.schema_version INT`. Legacy posts = `{}` → fully backward compatible; old app versions keep posting successfully (column has a default).
3. **Flutter dynamic renderer** — a `CategorySchemaService` (fetch + offline cache + bundled fallback) and a `SchemaForm` widget that renders any schema. Adding a category or question = **inserting a DB row. Zero app code.**

### 2.2 Question schema format (per category)
```json
{
  "version": 1,
  "fields": [
    {"key": "brand",     "label": "Brand",            "type": "select",  "options": ["HP","Dell","Lenovo","Apple","Other"], "required": true,  "highlight": true},
    {"key": "model",     "label": "Model",            "type": "text",    "required": false},
    {"key": "issue",     "label": "What's the issue?","type": "select",  "options": ["Won't power on","Screen","Battery","Slow","Other"], "required": true, "highlight": true},
    {"key": "warranty",  "label": "Under warranty?",  "type": "boolean", "required": false},
    {"key": "post_types","appliesTo": ["request","job"]}
  ]
}
```
- **Field types (v1):** `select` (chips), `multiselect`, `boolean` (toggle), `text`, `number`. Unknown types are **skipped, not fatal** — forward compatibility for older app builds.
- `appliesTo` lets one category ask different questions for request vs offer vs job.
- `highlight: true` marks the 1–2 answers surfaced on the feed card ("HP • Screen issue").
- **Evolution rules:** keys are append-only and never renamed/retyped; breaking changes bump `version` (old posts stay interpretable via their stored `schema_version`).
- **Friction cap:** 3–6 questions per category, most optional — Uber-grade polish means fewer, smarter questions, not more.

### 2.3 What deliberately does NOT change
- `posts.category` stays a TEXT name string (feeds, `inFilter`, admin analytics untouched).
- The existing wizard structure, image handling, urgency/pricing/location fields.
- The generic form remains the **permanent fallback**: schema missing / fetch failed / offline first-run / 'Other' category → today's exact experience. **Posting must never be blocked by the schema layer.**
- Offline mode, caching, connectivity detection, startup routing.

### 2.4 Where validation lives (phased)
- **MVP:** in-app validation from the schema (required/type/options) + Postgres CHECK `jsonb_typeof(attributes)='object'`. Same trust model as every existing post field.
- **Hardening (later, converges with the security roadmap):** post creation moves behind a NestJS `POST /posts` endpoint that validates attributes against the server schema; `posts` anon-write is then revoked (the already-deferred posts RLS lockdown). Designed for, not built now.

---

## 3. MIGRATION STRATEGY

Numbering: **070+ reserved for product-schema migrations** (security track keeps 063–069). All additive and reversible; zero data rewrites.

| # | Migration | Contents | Rollback |
|---|---|---|---|
| 070 | `categories.sql` | `categories` table (id slug PK, name UNIQUE, icon, sort, active, question_schema JSONB, schema_version INT, timestamps); seed 32 rows from `Category.all` (names byte-identical); `GRANT SELECT TO anon, authenticated` (read-only for clients) | `DROP TABLE categories` |
| 071 | `post_attributes.sql` | `ALTER TABLE posts ADD COLUMN attributes JSONB NOT NULL DEFAULT '{}'::jsonb, ADD COLUMN schema_version INT; CHECK (jsonb_typeof(attributes)='object')` | drop columns |
| 072 | `attributes_index.sql` (deferred to SP-4) | `CREATE INDEX ... ON posts USING GIN (attributes jsonb_path_ops)` | drop index |

- No backfill: legacy posts legitimately have `{}`.
- The Dart `Category.all` list stays in the app as the **bundled offline fallback** until SP-2 is proven, then becomes fallback-only (never deleted while old app versions exist).

---

## 4. IMPLEMENTATION PHASES (incremental, each independently shippable)

- **SP-1 — Foundation (no visible change):** migrations 070+071; `CategorySchemaService` in Flutter (fetch categories, 24h offline cache, bundled fallback asset); category dropdown reads from the service (list identical to today). Proves the plumbing with zero UX risk.
- **SP-2 — Dynamic question step:** `SchemaForm` renderer; wizard gains a "Details" step **only when the chosen category has a schema**; ship schemas for ~6 pilot categories (Laptop/Phone Repair, Plumber, Electrician, Tutor, Cleaner, Pets); answers written to `attributes`. Everything else falls through to the current form.
- **SP-3 — Smart display:** detail sheets (both copies — `discover_screen.dart` and `messages_screen.dart`) render attributes as labeled rows from the schema; feed card shows `highlight` chips. Admin marketplace pages optionally show attributes read-only.
- **SP-4 — Search & filters:** GIN index (072); per-category filter chips in the filter sheet driven by the same schema; provider-side matching improvements.
- **SP-5 — Server hardening:** backend `POST /posts` with schema validation; revoke anon INSERT/UPDATE on posts (executes the already-planned posts RLS lockdown); admin CRUD UI for category schemas (until then, schemas are managed by SQL insert — acceptable for a solo operator).

---

## 5. RISK ASSESSMENT

| Risk | Severity | Mitigation |
|---|---|---|
| Schema fetch fails / offline first-run → posting blocked | HIGH if unhandled | Hard rule: generic form is always the fallback; bundled asset ships in the APK; cache-first reads |
| Old app versions post without `attributes` | Certain | Column default `'{}'`; readers treat missing keys as absent |
| Client can write arbitrary attributes (direct Supabase insert) | Same as today's fields | Accepted for MVP (no worse than status quo); closed in SP-5; attributes never drive money/lifecycle logic |
| Category rename breaks feeds/filters/admin analytics | MEDIUM | `id` slug is the stable identity; `name` seeded byte-identical; renames deferred until posts carry a slug reference |
| Schema evolution corrupts old posts' meaning | MEDIUM | Append-only keys; `schema_version` pinned per post; version bump for breaking changes |
| Question fatigue hurts conversion | MEDIUM | 3–6 questions max, mostly optional; measure post-completion rate per category before expanding |
| Duplicated detail view drifts (`messages_screen.dart:2814`) | LOW | SP-3 extracts one shared attributes-rendering widget used by both |
| JSONB filter queries slow at scale | LOW (current volume) | GIN index in SP-4, only when filtering ships |

---

## 6. TESTING STRATEGY

- **Unit (Dart):** schema parser — every field type; unknown type skipped; `appliesTo` filtering; required-field validation; version handling. `CategorySchemaService` — cache hit/expiry, fetch failure → bundled fallback, malformed JSON → fallback.
- **Widget tests:** `SchemaForm` renders a fixture schema (chips/toggle/text/number); required gating blocks Preview; generic form appears when schema absent.
- **DB tests (SQL, like the settlement suite):** 070/071 idempotent re-run; insert post with/without attributes; CHECK rejects non-object attributes; legacy CHECK constraints (type/urgency/pricing/employment trigger) still enforced.
- **Regression matrix (manual, per phase):** post each of Request/Offer/Job × {pilot category, non-schema category, offline} → row lands correctly, feeds/filters/admin unchanged; archive/lifecycle/payment flows untouched (they never read attributes).
- **Rollout guard:** SP-2 behind a remote kill-switch (a `smart_posting_enabled` flag row) so the dynamic step can be disabled server-side without an app release.

---

## 7. Decision needed before implementation
1. Approve JSONB-attributes + categories-registry approach (§2) vs. alternatives considered and rejected: per-category child tables (migration per category = violates "no code changes"), EAV rows (query complexity, no atomic answers), backend-first (blocks on security phase).
2. Confirm the 6 pilot categories for SP-2.
3. Confirm SP-1 + SP-2 as the first implementation slice.
