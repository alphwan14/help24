# 🎯 Posting Redesign — Per-Intent Workflows (Product Design Proposal)

> Status: **COMPLETE — R-1/R-2/R-3 VERIFIED on device; R-4 (read-side alignment) IMPLEMENTED 2026-07-12, awaiting device verification. The per-intent posting redesign is fully built.**
>
> **R-4 artifacts:** `mobile-app/lib/models/attribute_display.dart` (+19 tests) — pure read-side resolver: per-intent money labels (`Budget KES X`/`Open to offers`, `From KES X/hr`, `KES X/mo`), time-signal chips from reserved keys (availability/start), highlight-answer chips (capped, schema-labeled), and full Q/A rows for detail sheets. Wired into: `post_card.dart` (intent tags — urgency only for requests, availability/start for offers/jobs, highlight chips; dead always-"Medium" difficulty tag removed; money row shows "Open to offers" at price 0), `discover_screen.dart` detail sheet (Budget/Starting price/Salary row, Q/A rows, fake Difficulty row removed), `messages_screen.dart` `_PostDetailPage` (same), `JobModel` (parses `pricing_type`; pay renders "KES 25,000/mo"; `normalizePayDisplay` preserves rate suffixes), `main.dart` (registry warm-up at bootstrap, fire-and-forget cache-first). Reverse wire lookups added to the three flow models. **Deferred:** admin-dashboard money labels (Next.js surface — cosmetic, untouched; posts render as before there).
>
> **R-3 artifacts:** `mobile-app/lib/models/job_flow.dart` (+14 tests) — start-date enum (`_start` reserved key, urgency constant `flexible`), step sequence (deliberately NO photos step — jobs are recruitment), required-salary validation. `JobModel` gained `pricingType` (salary period → posts.pricing_type; was hardcoded 'task'). Migration `074_job_question_schemas.sql` — recruitment-voiced questions (work type / experience required / etc.) for the 7 pilots; requester steps re-scoped to `["request"]` only; schema version 3 (canonical schema source is now 074; rollback = re-run 073). `post_screen.dart` — job step engine (Category → Job title → Employment tiles → Salary + period chips → Start date → Job questions → Role description (required) → Location → Preview), **legacy single-form deleted** (all three intents now guided; `_buildFormStep`/`_canProceed`/`_getMissingFieldsText`/`_questionStepEnabled` removed), job submits never upload stale images. Broken template `test/widget_test.dart` deleted — `flutter test` now passes wholesale (60 tests).
>
> **R-2 artifacts:** `mobile-app/lib/models/offer_flow.dart` (+13 tests in `test/offer_flow_test.dart`) — availability enum (`_availability` reserved key, urgency column constant `flexible`), step sequence, required starting-price validation. Migration `073_offer_question_schemas.sql` — provider-voiced questions (services offered / experience) for the 7 pilots, requester-voiced steps scoped to `applies_to ["request","job"]`, schema version 2 (supersedes 072's content; re-run 073, not 072). `post_screen.dart` — offer step engine (Category → Title → Provider questions → Starting price + rate chips → Availability → Location → Portfolio → Pitch → Preview), type-switch state isolation (`_selectType` resets per-intent state so a request's "Right now" can never leak into an offer), preview shows "From KES X · rate" + availability chip instead of urgency. Location step included (offers need it for the feed) even though the approved list omitted it — flagged for owner review.
> Builds on Smart Posting SP-1/SP-2 (category registry + guided questions), which stay as-is.

## ⚠️ Approved revisions to this proposal (product owner, 2026-07-12)

The owner approved the architecture with one philosophy change — **posting must stay natural, not conversational/AI-driven**, because Kenyan users write in English, Kiswahili, Sheng, and mixes ("Nahitaji fundi wa fridge", "TV yangu imekufa"):

1. **Titles stay MANUAL — never auto-generated.** Users write titles in their own language; future AI may use them for search/recommendations, but posting stays natural.
2. **Descriptions:** Requests → optional, renamed "Anything else?". Offers → kept (providers market themselves). Jobs → kept (employers explain the role).
3. Approved request order: Category → Title → When? → smart questions → Budget (Open to offers / My budget / Skip) → Location → Photos → Anything else? (optional) → Review.
4. Schemas COMPLEMENT the user's own words; they never replace them.
5. Everything else from the original proposal stands (per-intent flows, When?/Availability/Start-date semantics, Budget/Starting-price/Salary differentiation, reserved attribute keys, no new migrations, R-1→R-4 order with a stop after each phase).

### R-1 implemented artifacts
- `mobile-app/lib/models/request_flow.dart` — pure journey logic (When mapping → legacy urgency column, step sequence, budget semantics, `_when` reserved-key composition). 14 unit tests in `test/request_flow_test.dart`.
- `post_screen.dart` — request-only step engine (Category search-list → Title → When → Questions → Budget → Location → Photos → Details → Preview); offers/jobs untouched on the legacy form until R-2/R-3. Shared `ChoiceTile` (now public in `schema_question_flow.dart`), shared location/image-strip builders, step transition animation.
- Read-side: empty descriptions render cleanly (post_card, discover detail sheet, messages detail page).
- No new migrations; Supabase payload shape unchanged (attributes gains `_when`).

---

## 1. Product-design audit of the current flow

The current wizard treats three fundamentally different intents as one form:

| | Request ("I need help") | Offer ("I provide a service") | Job ("I'm hiring") |
|---|---|---|---|
| The user is | a buyer, often stressed, sometimes in an emergency | a seller marketing capability | an employer defining a role |
| Money means | **Budget** — what I'll pay (may not know; "open to offers" is valid) | **Starting price** — "from KES X" (a seller MUST price) | **Salary / Pay** — usually per month |
| Time means | **When do I need this?** (right now / today / flexible) | **Availability** (available now / by appointment) | **Start date** (immediately / within a month) |
| Description is | mostly redundant once smart questions are answered | the sales pitch — important | the role definition — important |
| Title is | a composition burden duplicating structured data | brandable but composable | composable from role + type |

Concrete UX defects, screen by screen:

1. **Title first = typing first.** The very first field forces free-text composition ("Leaking sink Westlands urgent") that duplicates category + schema answers + location + urgency we collect two screens later. Worst possible ordering for an emergency.
2. **One "Urgency" chip row for all intents.** "Urgent / Soon / Flexible" is a *request* concept. An offer is never "urgent"; a job needs a start date. The same three chips render for all three.
3. **One price field, one label rule.** Budget vs starting price vs salary differ in meaning, required-ness, and unit (task vs "from"/rate vs per-month), but share one numeric field + a generic "Pricing" dropdown that most requesters shouldn't see.
4. **Category is a dropdown** — 32 items in a scroll wheel, slow with one thumb; and it sits mid-form even though it's the routing key that unlocks the smart questions.
5. **Description is required everywhere**, even when the guided answers already describe the need better than the user would.
6. **Job posts previously discarded category/urgency** (fixed in SP-2) — symptomatic of the job intent being bolted onto the request form.

Principle for the redesign: **tap-first, type-last, category-first.** Structured taps produce the post; free text becomes optional garnish; typing is never required in an emergency.

---

## 2. Proposed user journeys

### 2.1 REQUEST — "I need help" (optimized for speed & emergencies)

```
[Intent] → [Category] → [When?] → [Smart questions] → [Budget] → [Where + photos] → [Review → Post]
```

1. **Category** — searchable chip grid (big targets), not a dropdown. Suggested/recent on top.
2. **"When do you need this?"** — `Right now (emergency)` / `Today` / `This week` / `Flexible`. Natural language replaces the abstract urgency chips. `Right now` switches the whole flow to emergency mode (SP-2's trimmed questions) and keeps today's urgent behavior (urgent badge + 1h urgent window).
3. **Smart questions** — existing SP-2 guided flow, auto-trimmed in emergency.
4. **Budget** — "What's your budget?" numeric **with a first-class `Open to offers` skip**. Requesters often don't know a fair price; forcing a number produces garbage data.
5. **Where + photos** — city/area pre-confirmed from cached location (one tap to accept), photos optional.
6. **Review** — an auto-composed card: generated title + generated summary from the answers, one optional "Anything else?" free-text field. Both editable. Post.

**Emergency tap budget** (burst pipe): Request → Plumbing → Right now → Burst pipe → water-off Yes/No → Open to offers → confirm location → Post = **~8 taps, zero typing.**

### 2.2 OFFER — "I provide a service" (optimized for credibility)

```
[Intent] → [Category] → [Smart questions] → [Starting price + rate] → [Availability] → [Where + photos] → [Review → Post]
```

1. **Category** — same chip grid.
2. **Smart questions** — schemas already support `applies_to: ["offer"]` for seller-side questions (e.g. Tutoring: subjects, levels, mode).
3. **Starting price** — "Your starting price" + rate unit (per task / hour / day) rendered as "**from KES X/hour**". **Required** — a seller must price.
4. **Availability** — `Available now` / `This week` / `By appointment`. Replaces urgency (stored in attributes, see §4).
5. **Where + photos** — photos promoted here (portfolio matters for sellers).
6. **Review** — generated title ("Plumbing services — from KES 500"), plus "Describe your service" free text (optional but prominently nudged — it's the pitch).

### 2.3 JOB — "I'm hiring" (optimized for role clarity)

```
[Intent] → [Category] → [Employment type] → [Salary] → [Start date] → [Smart questions] → [Role description] → [Where] → [Review → Post]
```

1. **Category** → 2. **Employment type** — big chips (required; DB trigger already enforces it).
3. **Salary / Pay** — amount + period (per month default; per day/week for casual work) → maps onto `price` + `pricing_type` (month/week/day already in the enum).
4. **Start date** — `Immediately` / `Within a month` / `Flexible` (stored in attributes).
5. **Smart questions** (`applies_to: ["job"]`), 6. **Role description** — free text, required (a job ad needs it).
7. **Review** — generated title ("Hiring: House Cleaning — Full-time, KES 15,000/month"), editable.

---

## 3. Intelligent generation (no AI dependency — deterministic, offline-safe, always editable)

- **Title templates** (pure function, unit-tested):
  - Request: `"{Category} needed — {primary highlight answer}"` (+ " (urgent)" when emergency) → *"Plumbing needed — Burst pipe (urgent)"*. Fallback without answers: `"{Category} needed"`.
  - Offer: `"{Category} — from KES {price}{/rate}"` → *"Tutoring — from KES 800/hour"*.
  - Job: `"Hiring: {Category} — {Employment type}"`.
- **Summary/description composition**: sentence-per-answer from schema labels (*"Issue: Burst pipe. Water is shut off. Location: Westlands, Nairobi."*) + the user's optional free text appended. For requests this REPLACES the required description; for offers/jobs the free text remains the main body with the answer summary appended.
- Titles regenerate live as answers change until the user edits the field manually (then their edit wins — tracked in-session, and flagged via `attributes._auto_title`).

## 4. Data model changes (deliberately near-zero — fully backward compatible)

| Concern | Change | Migration needed? |
|---|---|---|
| Generated titles/descriptions | none — `title`/`description` stay NOT NULL and are always supplied | **No** |
| Budget "Open to offers" | `price = 0` already means it; read side renders the label (display change) | **No** |
| Budget vs from vs salary labels | derived from existing `type` + `pricing_type` on the read side | **No** |
| Offer availability / job start / request "when" precision | stored in `attributes` under **reserved keys** `_availability`, `_start`, `_when` (schema question keys may not start with `_`) | **No** (071 already shipped) |
| Auto-title marker | `attributes._auto_title: true` | **No** |
| Urgency column mapping | Request: Right now→`urgent`, Today→`soon`, This week/Flexible→`flexible`. Offer/Job: constant `flexible` (their real time signal lives in attributes) | **No** |

Old app versions keep posting through the old form — every column, CHECK constraint, and trigger is untouched. Feeds/admin keep working (title/description always present).

## 5. Implementation phases (each ships + verifies independently)

- **R-1 — Wizard engine + Request journey.** Refactor `post_screen.dart` into a step-descriptor engine (ordered list of small step widgets per intent; SchemaQuestionFlow becomes one step type) and ship the new Request flow. Tests: title/summary composer (pure), step-sequence resolver per intent, urgency mapping.
- **R-2 — Offer journey** (starting price + availability).
- **R-3 — Job journey** (employment → salary → start).
- **R-4 — Read-side alignment** (feed cards + detail sheets: "Budget/Open to offers", "from KES X/hr", "KES X/month"; absorbs Smart Posting SP-3 attribute display).

## 6. Risks

| Risk | Mitigation |
|---|---|
| Auto-titles feel robotic in feeds | deterministic templates from human labels; always editable; `_auto_title` flag lets us improve rendering later |
| Optional request descriptions → thinner posts | schema answers carry the substance and R-4 displays them on cards; free-text prompt still offered at review |
| Refactoring the posting path (the app's core write) | engine refactor is R-1's first commit with behavior parity before UX changes; payload shape to Supabase unchanged; per-step widget tests |
| Chip-grid with 32 categories | search field + grouped sections + recent-first |
| Offers/jobs stop writing meaningful `urgency` | nothing reads urgency for offers/jobs today (urgent feed filters `type='request'`) — verified in audit |

## 7. Decision points for the product owner

1. Approve per-intent journeys as specified (§2)?
2. Request budget: confirm **"Open to offers" as a first-class skip** (price=0 semantics)?
3. Request description: confirm demotion to **optional** "Anything else?" (answers + generated summary carry the post)?
4. Approve reserved attribute keys (`_when`, `_availability`, `_start`, `_auto_title`) instead of new columns?
5. Phase order R-1 → R-4 (Request first)?
