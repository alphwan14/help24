# 🧭 Professional Profile & Trust — Architecture

> Milestone: Professional Profile & Trust. Implemented 2026-07-24. **Local only — not committed, not pushed.**
> Stack: Flutter + Supabase (Postgres) + NestJS.

---

## 1. The thesis

Help24 already had a *correct* trust layer (`provider_reputation`, service-role-only, recomputed by SQL) and a *weak* identity layer (a flat edit form, a free-text profession, no provider profile anywhere). This milestone fixes the identity half so a client can answer "who is this person and should I hire them?" without leaving the application list.

Three rules governed every decision:

1. **One source of truth.** No new user table, no `is_provider` flag, no duplicated phone editor, no mirrored profession column.
2. **No existing user breaks.** Every change is additive; legacy data renders exactly as it did.
3. **The future is declared, not built.** Service Area, Skills, Portfolio, Certificates, Languages, Years of Experience and Business Name exist in the architecture today as `comingSoon` registry entries — shipping one is a status flip, not a redesign.

---

## 2. Data model

### 2.1 There is still exactly one person record

`public.users` remains the only identity table. **A provider is a derived state, not an entity:**

```
provider-ready  ==  ProfessionRegistry.isConfirmed(users.profession)
                AND users.phone_number IS NOT NULL
```

Computed in `ProviderReadiness.of(...)`. Nothing to backfill, nothing that can drift.

> `public.providers` + the NestJS `/providers/register|verify-payout|change-payout` endpoints are **legacy and unused by the app** (verified: no Dart call sites). They were left untouched — deleting them is a separate cleanup.

### 2.2 Profession became a controlled key in the same column

`users.profession` previously held free text ("electrician", "Electrician", "Electrical", "Electrical Works"). It now holds `professions.id` — a stable slug.

**Why the same column and not a new one:** `users.profession` had exactly two readers in the whole repo (the profile hero and the edit form) — nothing in the backend, nothing in the admin dashboard. A second column would have been pure duplication.

**Legacy handling — nobody loses their data:**

| Stored value | `resolve()` | `labelFor()` (what is shown) | `isConfirmed()` (completion / gate) |
|---|---|---|---|
| `electrician` | Profession | "Electrician" | ✅ |
| `Electrician` (old display name) | Profession | "Electrician" | ✅ |
| `Electrical Works` (legacy prose) | `null` | **"Electrical Works"** — verbatim | ❌ |
| `''` | `null` | `''` | ❌ |

Legacy prose keeps rendering everywhere; it just leaves the completion box unticked and shows a "Tap to confirm from the list" nudge. That is what migrates the data — not a destructive UPDATE.

### 2.3 Name changes are rate-limited in Postgres

`users_update_own` (migration 011) lets a signed-in user UPDATE their own row from the client. A Dart-only cooldown would be decorative, so migration 087 installs a `BEFORE UPDATE` trigger that owns `users.name_changed_at`:

- name unchanged → the stamp is pinned to its old value (**a client cannot reset its own cooldown**)
- name changed, last change > 30 days ago (or never) → allowed, stamp set to `now()`
- otherwise → `RAISE` with the `HELP24_NAME_COOLDOWN` marker, which `ErrorMapper` renders as a rule

Name **shape** validation stays in Dart (`utils/name_validator.dart`) deliberately: shape rules are product judgement and must not need a migration to tune. The trigger owns only the part the client cannot be trusted with.

---

## 3. Migrations (2, both additive, both degrade gracefully)

| File | Purpose | App behaviour if NOT applied |
|---|---|---|
| `086_professions.sql` | Controlled vocabulary registry (17 seeded). Adding a trade later = one INSERT. | ✅ Fully functional — the client ships `Profession.bundled`, byte-identical to the seed |
| `087_users_name_change_guard.sql` | `name_changed_at` + cooldown trigger | ⚠️ Dart guard still applies; the server-side limit is absent |

Deliberately **not** done:
- No FK/CHECK on `users.profession` — it would reject every legacy row on its next unrelated UPDATE.
- `public_profiles` not extended — deferred to the planned 063 users-PII lockdown, where profession/bio/created_at should be added in one pass. `UserProfileService.getPublicProfile` is the single call site to repoint then.
- Dead columns from migration 012 (`average_rating`, `total_reviews`, `completed_jobs_count`) left alone — a separate cleanup with the admin dashboard.

---

## 4. Client architecture

```
models/
  profession.dart            Profession + bundled fallback list
  profile_completion.dart    ProfileFieldSpec registry · ProfileFacts · ProfileCompletion
  theme_preference.dart      ThemePreference (system|light|dark) → ThemeMode
  user_model.dart            users row (+ nameChangedAt; dead Firestore path removed)

services/
  profession_registry.dart   memory → SharedPreferences(24h) → bundled

utils/
  name_validator.dart        shape validation, normalization, NameChangePolicy
  icon_keys.dart             shared server-icon-key → IconData (categories + professions)

widgets/
  profile_widgets.dart       ProfessionChip · ProfileAvatar · CompletionRing ·
                             ProfileSectionCard · ProfileFieldRow · ProfileEditorSheet
  profile_editors.dart       name / profession / bio — one field each
  provider_gate.dart         ProviderReadiness + ensureProviderReady()
  applicant_card.dart        THE hiring-decision card + ApplicantTrustStrip

screens/
  professional_profile_screen.dart   the hub (replaced edit_profile_screen.dart)
  provider_profile_screen.dart       public, read-only provider profile
```

### 4.1 Profile completion is computed, never stored

A stored percentage goes stale the moment a field is added. `ProfileCompletion.evaluate(ProfileFacts)` derives it from a declarative registry:

```dart
ProfileFieldSpec(
  key: 'service_area', label: 'Service area',
  section: ProfileSection.professional, weight: 15,
  status: ProfileFieldStatus.comingSoon,   // ← excluded from the percentage
  satisfiedBy: (_) => false,
)
```

Active weights sum to 100 (asserted by a test) so each weight reads as a percentage point:

| Field | Weight |
|---|---|
| Profile photo | 20 |
| Full name | 10 |
| Phone number | 20 |
| Profession | 25 |
| About you | 25 |

**Coming-soon fields are excluded from the percentage on purpose.** The spec's example checklist shows `□ Service Area`, but a permanently unreachable box caps everyone below 100% and reads as a dead end. They are instead listed in a muted "Coming soon" group so the roadmap is visible while today's profile is completable.

**To ship a future field:** add its fact to `ProfileFacts`, flip `status` to `active`, add a `ProfileFieldRow` + editor. The ring, the checklist, the Account tile subtitle and the gate all update themselves.

### 4.2 Profession registry mirrors the category registry

`ProfessionRegistry` is a deliberate structural copy of `CategorySchemaService`: same cache keys shape, same 24h TTL, same "stale cache beats a failed fetch", same synchronous getters, same fire-and-forget `warmUp()` from `_runBackgroundBootstrap`. Two registries behaving identically is a feature.

### 4.3 Theme

`bool isDarkMode` → `ThemePreference {system, light, dark}`.

- `MaterialApp.themeMode` now gets `ThemeMode.system` when chosen; every existing `Theme.of(context).brightness` read across the app is untouched.
- The system UI overlay style is resolved manually (`ThemePreference.isDark(platformBrightness)`) because the framework does not derive it from `themeMode`. `_Help24AppState` observes `didChangePlatformBrightness` so Device Default reacts to an OS toggle or a night schedule immediately.
- **Legacy migration (one-time, non-breaking):** `themeMode` present → use it; else `isDarkMode` present → the user explicitly toggled the old switch, so preserve it as an **explicit** Light/Dark (never "system", which could visibly change their app); else → Device Default.

---

## 5. Trust surfaces

### 5.1 One applicant card, two screens

`ApplicationsScreen` and `post_detail_screen`'s applicants list previously rendered the same decision two different ways — one with a trust block, one with nothing but a name and a timestamp. Both now render `ApplicantCard`:

photo · name · **profession chip** · applied-when · tier badge · rating(count) · jobs done · completion % · member since · message · **View Profile / Message / Accept**

Profession rides on the application (the `users` join gained `profession`), so there is no extra fetch per card. Everything else comes from `ReputationService`, which already batches, caches (3-min TTL) and de-dupes in-flight requests per provider.

**Honesty rules baked into `ApplicantTrustStrip`:** a completion rate over zero concluded jobs is not a fact, so it is omitted; a provider with no history reads "New on Help24", never `0 jobs · 0% · 0%`; a failed reputation read says "Reputation unavailable" rather than rendering zeros.

Per spec §4, profession is **not** on post cards — the job card stays about the job.

### 5.2 The provider profile that did not exist

`ProviderProfileScreen(providerId)` is the destination "View Profile" never had: avatar, name, **profession** (directly under the name — the primary trust indicator), tier badge, member since, the same `ReputationProfileSection` the account tab uses (so the numbers can never disagree), bio, and paginated reviews with provider replies. Read-only; save-provider and message actions reuse `SavedService` and `ChatScreen`.

### 5.3 One become-a-provider gate

Before: offering on a request required an M-Pesa number; applying to a **job** required nothing at all. Both now call `ensureProviderReady(context, uid:)`, which shows a sheet listing exactly what is missing, routes to the Professional Profile, re-checks on return, and **resumes the original action** when satisfied.

It **fails open** on a network error: not knowing whether someone is qualified is not a reason to stop them working.

Profession is required *here* and nowhere else — sign-up stays frictionless (spec §3).

---

## 6. Files changed

**New (13)**
`models/profession.dart`, `models/profile_completion.dart`, `models/theme_preference.dart`,
`services/profession_registry.dart`, `utils/icon_keys.dart`, `utils/name_validator.dart`,
`widgets/profile_widgets.dart`, `widgets/profile_editors.dart`, `widgets/provider_gate.dart`, `widgets/applicant_card.dart`,
`screens/professional_profile_screen.dart`, `screens/provider_profile_screen.dart`,
`supabase/migrations/086_professions.sql`, `supabase/migrations/087_users_name_change_guard.sql`

**Modified (12)**
`main.dart` (theme resolution, brightness observer, profession warm-up),
`providers/app_provider.dart` (ThemePreference + legacy migration),
`models/user_model.dart` (`nameChangedAt`, `memberSinceYear`; dead Firestore path removed),
`models/post_model.dart` (`Application.applicantProfession`),
`services/user_profile_service.dart` (focused writers + `getPublicProfile`),
`services/application_service.dart`, `services/post_service.dart` (joins select `profession`),
`services/category_schema_service.dart` (icon map extracted),
`screens/profile_screen.dart` (Theme picker, Professional Profile tile with ring, profession chip),
`screens/applications_screen.dart`, `screens/post_detail_screen.dart` (shared card),
`screens/jobs_screen.dart` (provider gate),
`utils/error_mapper.dart` (cooldown marker),
`assets/l10n/{en,sw}.json`

**Deleted (1)** — `screens/edit_profile_screen.dart` (replaced by the hub)

**Tests (4 new files, 40 tests)** — `name_validator_test.dart`, `profile_completion_test.dart`, `theme_preference_test.dart`, `applicant_trust_test.dart`

---

## 7. Known gaps / deliberate deferrals

1. **`public_profiles` view** does not yet expose profession/bio/created_at. `getPublicProfile` reads `users` directly (as the rest of the app does). Bundle the view change with the 063 PII lockdown.
2. **Name validation is English/Latin-tuned.** The character class is full Unicode, but the vanity deny-list is English. Non-Latin names pass shape checks; the deny list simply will not catch non-English handles.
3. **The "first + last name" rule** is enforced only on *change*. Existing single-word names are untouched and never retroactively invalidated.
4. **No profession-based search/filter yet** — this milestone makes it *possible* (a canonical key + a `category_id` link). Building it is future work.
5. **`public.providers` and the `/providers/*` endpoints remain dead code.**
