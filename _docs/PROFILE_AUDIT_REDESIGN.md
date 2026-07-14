# 👤 Profile Tab — Complete Audit & Production Redesign

> Status: audit complete 2026-07-14; redesign implemented same day (see §15).
> Stack note: Help24 is **Flutter + Supabase (Postgres) + NestJS**. There is no Firestore and no React Native — the "Firestore" audit maps to Supabase tables and backend endpoints. One stale docstring still says "Firestore" (edit_profile_screen.dart:13).

---

## 1–2. Current screen inventory & problems found

`profile_screen.dart` (1,498 lines), top to bottom:

| # | Element | Verdict |
|---|---|---|
| 1 | Identity hero (avatar 100, name, email, bio, profession) | **Keep** — clean, real data (`users` row), initials fallback, guest state handled |
| 2 | "Posts" stat card | **Redesign** — a full-width card holding a single centered number; not tappable; no My Posts destination exists anywhere in the app; excludes job posts arbitrarily; fetched by downloading up to 10,000 row IDs and counting client-side |
| 3 | `ReputationProfileSection` | **Keep core / fix edges** — the strongest part of the screen (see §5), but renders a zero-grid ("0 Jobs, 0%, 0%, 0 Disputes") for every pure client, and is cached for the whole app session so your own reputation goes stale |
| 4 | Account → Edit Profile | **Keep** |
| 5 | Account → Payment Settings | **Keep** — genuinely production-grade: biometric/`local_auth` gate before revealing or changing the M-Pesa number, masking, normalization. Minor: the tile subtitle shows the **unmasked** number |
| 6 | Account → "Privacy & Security" | **Remove** — it navigates to `PrivacyScreen`, the *same legal document* as Support → "Privacy Policy". A security-sounding menu item that opens a policy is misleading duplication |
| 7 | Preferences → Dark Mode / Notifications / Location / Language | **Keep** — all functional, optimistic updates, real persistence (`users.notifications_enabled`, `users.language`). Swahili honestly gated "Coming soon" |
| 8 | Support → Help Center / Terms / Privacy | **Keep** |
| 9 | Log Out | **Keep / fix** — confirm dialog good, but **the FCM token is not removed on logout**: the device keeps receiving the account's push notifications after signing out |
| 10 | Version "Help24 v1.0.0" | **Fix** — hard-coded string; will silently lie the first time pubspec's `version:` changes |

## 3–4. UX & information-architecture issues

- **No activity management.** The profile says "0/5/12 Posts" but offers no way to see or manage them — the single most-expected "control center" action is missing.
- **Duplicated navigation** (Privacy twice), **misleading label** (Privacy & Security ≠ security).
- **Zero-grid reputation for clients** — a user who has never provided a service sees "Jobs Completed 0 · Completion Rate 0% · Dispute Rate 0% · Open Disputes 0", which reads like a bad report card rather than "you're new here".
- The lone Posts card wastes a full row on one number; hierarchy is otherwise sound (identity → trust → settings → support → logout) and is preserved.
- Missing-but-deferred surfaces (see §11): wallet/earnings (blocked on Financial Automation phase), saved items (no such feature exists platform-wide), account deletion (needs backend + policy work).

## 5–6. DATA CORRECTNESS — every number traced to its source

**The verdict: the trust-critical stats are real, server-authoritative, and not client-forgeable.** No fake analytics were found. Exact chains:

| Stat | Chain | Source of truth | Client-manipulable? |
|---|---|---|---|
| Tier, Rating, Reviews | widget → `ReputationService` → `GET /reputation/:id` (NestJS) → `provider_reputation` row | **Derived by SQL fn** `fn_recompute_provider_reputation` (migration 055) from `reviews` (status='visible' only) | **No** — table is service_role-only (055:32-44) |
| Jobs Completed | same | COUNT DISTINCT approved `job_completions` on posts where `selected_provider_id = provider` | **No** — job_completions revoked from clients (060) |
| Completion Rate / Dispute Rate | same | completed ÷ concluded, concluded = posts `status IN ('completed','cancelled')` | Indirectly (see risks) |
| Open Disputes | same | COUNT non-terminal `disputes` | **No** — disputes revoked from clients (060) |
| Member Since | `/reputation/:id` also reads `users.created_at` | DB default at signup | **Weakly** — owner can UPDATE own users row; cosmetic only |
| Posts | direct client Supabase query: select up to 10k IDs where `author_user_id = uid AND type != 'job'`, count in Dart | `posts` table | Only by actually creating posts |

There are **no client-maintained counters** — the old `incrementCompletedJobsCount` was deliberately removed (Phase 3.2B) in favor of the single server-side recompute. The API returns more than the UI shows (`bayesian_rating`, `repeat_clients`, `disputed_jobs`, `last_active_at` — available for future surfaces).

**Real correctness risks found (with severity):**

1. 🔴 **Dead `users` columns still drive the ADMIN dashboard.** `users.average_rating / total_reviews / completed_jobs_count` (migration 012) have **no writer anywhere** since the client incrementer was removed — yet the admin dashboard reads them in **six places** (users list, active users, marketplace KPIs, completed page, provider insights, overview). Admin shows zeros/stale numbers that contradict the app. → Backend follow-up: migrate admin reads to `provider_reputation`, then drop the dead columns (documented, not done in this phase).
2. 🟠 **Recompute is event-gated and misses cancellations.** `provider_reputation` refreshes on review submit, job approval, and dispute resolution — but the completion/dispute-rate *denominator* includes cancelled posts, and **no recompute fires on cancellation**. Rates can be stale until the next triggering event. → Backend follow-up: recompute on post cancellation (or nightly sweep).
3. 🟠 **posts UPDATE RLS is wide open** (`USING(true)` + anon UPDATE grant): theoretically a client could set another user as `selected_provider_id` on a cancelled post to poison their rates. Already on the security roadmap as the posts-table lockdown; this audit sharpens the motivation.
4. 🟡 **Session-lifetime reputation cache**: `ReputationService._cache` never expires; your own profile's reputation won't update until app restart. → **Fixed in this phase** (TTL).
5. 🟡 **Posts count query** downloads IDs to count them. → **Fixed in this phase** (server-side `count`).
6. 🟡 `users.fcm_tokens` **column** is legacy (writes go to the `fcm_tokens` **table**); one old edge function still reads the column. Cleanup follow-up.
7. 🟡 `supabase_schema.sql` bootstrap defines a permissive `users_update USING(true)` policy that migration 011 never drops by that name — if the bootstrap file was ever applied, it would OR-defeat the owner-only policy. Resolved properly by the planned users lockdown (063).

## 7–12. Redesign (implemented)

**Purpose shift: "user information" → the user's control center.** Final hierarchy:

1. **Identity** — hero (avatar, name, contact, bio/profession). Unchanged visually; now fed by a **single** users stream.
2. **Trust & Reputation** — server-verified stats only. New-user honest state: *"New on Help24 · Member since YYYY — stats appear after your first completed job"* instead of a zero-grid. Providers keep the full grid.
3. **My Activity** *(new)* — "My Posts" tile with live count → **new `MyPostsScreen`**: all authored posts (requests, offers **and jobs** — the old count arbitrarily excluded jobs), rendered with the standard feed card, tap → Job Lifecycle Detail (the management view), pull-to-refresh, real empty/error states.
4. **Account** — Edit Profile; Payment Settings (subtitle now shows the **masked** number, biometric gate unchanged).
5. **Preferences** — Dark Mode, Notifications, Location, Language (unchanged).
6. **Support & Legal** — Help Center, Terms, Privacy Policy. *(duplicate "Privacy & Security" removed)*
7. **Log Out** — now also **removes this device's FCM token** (best-effort) so a signed-out device stops receiving the account's pushes. Notification *preference* is untouched.
8. **Version** — read from the package at runtime (`package_info_plus`), never hard-coded again.

**Removed:** Privacy & Security duplicate; lone Posts stat card; zero-grid for non-providers; hard-coded version.
**Added:** My Activity section + MyPostsScreen; masked payment subtitle; logout token removal; honest new-user reputation state.

## 13–14. Performance & backend improvements

Implemented now (client):
- **users-row polling halved**: the screen previously ran **two** parallel `watchUser` pollers (header + Account section), each doing a full-row select every 15s. Now one stream feeds the whole screen.
- `ensureProfileDoc` no longer fires from inside `build()` (was a side-effectful insert attempt on every rebuild while data was null); it runs at most once per screen life, post-frame.
- Posts count via PostgREST `count=exact` (no row download), includes all post types, excludes archived.
- Reputation cache gains a 3-minute TTL (feed cards still dedupe/coalesce; own profile refreshes on re-entry).

Recommended backend follow-ups (documented, deliberately not bundled into a UI phase):
- Point the six admin-dashboard reads at `provider_reputation`; drop dead `users` stat columns (needs its own migration + admin release).
- Trigger `recompute()` on post cancellation, or add a nightly recompute sweep.
- Posts RLS lockdown (existing security-roadmap item; now with the rate-poisoning rationale).
- Retire the `users.fcm_tokens` column + the legacy `send-chat-push` reader.
- Future: wallet/earnings section on the profile once the Financial Automation phase lands (transactions data already exists server-side).

## 15. Implementation (this phase)

Files: `profile_screen.dart` (restructure), **new** `screens/my_posts_screen.dart`, `services/user_profile_service.dart` (count fix + `getAuthoredPosts`), `services/reputation_service.dart` (TTL), `services/notification_service.dart` (`removeTokenOnLogout`), `providers/auth_provider.dart` (logout hook), `widgets/reputation_widgets.dart` (new-user state), `utils/phone_utils.dart` (`maskPhone` + tests), `pubspec.yaml` (`package_info_plus`).
