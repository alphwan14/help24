# Help24 — Full Architecture Audit and Configuration Roadmap

Status: **audit only. No code changed, no migration written, nothing applied.**
Written after Phase 0/1 (the remote configuration plane) went live in production
on 2026-08-07. Companion documents: `backend-centric-architecture-assessment.md`
(the original architecture review) and `phase0-1-implementation-plan.md` (what
shipped, and its production verification log).

Every claim below is cited to `file:line` or to a live-database query run against
production during this audit.

---

## 0. Read this first — what outranks the roadmap

The audit was asked to look for configuration candidates. It found things that
are more urgent than anything in the roadmap, so they lead. Two are P0, one is a
correction to an earlier claim of mine, one is a contained P1, and one section
records what was checked and found already safe.

### 0.1 P0 — Six funded payments have no escrow row, and the repair path has never worked

Measured against production:

```
funded transactions ever : 11
missing an escrow row    :  6   (55%)
value affected           : KES 24,550 (amount) / KES 24,895 (total paid)
statuses affected        : paid, payout_pending, disputed
window                   : 2026-06-01 → 2026-06-18
```

Every one of the 11 dead-lettered `payment.success` events carries the same error:

> `Escrow upsert failed for tx <id>: there is no unique or exclusion constraint matching the ON CONFLICT specification`

**Root cause.** `backend/src/events/event-processor.service.ts:226` upserts the
repair row with `{ onConflict: 'transaction_id' }`, but `public.escrow` has no
unique constraint on `transaction_id` — its only unique constraint is
`escrow_job_id_key UNIQUE (post_id)` (verified against `pg_constraint`).
Postgres rejects the statement outright, so the escrow-repair handler has
**never** succeeded, on any event, since it was written.

**Why it matters.** Escrow is the record of held funds. When the optimistic
insert at payment-initiate fails (`mpesa.service.ts:297-316` deliberately
tolerates that failure *because* this handler is supposed to repair it), the row
is now permanently absent. Downstream, `escrow` is what the archive gate reads to
block archiving a post with held money (`jobs.service.ts:641-655`), and what the
settlement engine reconciles against. One affected transaction is in
`payout_pending` and one is `disputed` — both with no escrow row.

**Not fixed, merely dormant.** There has been no payment traffic since 2026-06-22,
so the failure has had no opportunity to recur. The next payment that hits the
optimistic-insert path will fail identically.

This needs a decision from you: it is a code fix plus, most likely, a corrective
data migration to reconstruct the six missing rows. I have not written either.

### 0.2 P0 — Authentication is declared but not enforced in production

Probed live, with no credentials of any kind:

| Route | Declared | Production response |
|---|---|---|
| `GET /jobs/:postId/status` | `@Auth()` — `jobs.controller.ts:94` | **200** |
| `GET /reviews/eligibility/:postId` | `@Auth('query.user_id')` — `reviews.controller.ts:32` | **200** |
| `POST /feed/interactions` | `@Auth('body.user_id')` — `feed.controller.ts:83` | **202** |

`AUTH_ENFORCEMENT` is still `off` or `monitor` in the production environment. The
entire identity-binding mechanism — the work that makes every ownership check in
every service actually mean something — is shipped, audited at boot, and inert.

The staging design is correct and deliberate (`auth.types.ts:9-39`): ship in
monitor, watch `authWouldDeny` fall to zero, then flip. The flip appears never to
have happened. Until it does, the backend's authorization model is advisory.

This is an environment-variable change plus a restart, but it must not be done
blind — flipping it while a real client still trips a binding would sign users
out mid-flow. The correct next step is to read the `authWouldDeny` counter from
production access logs and decide from that number.

### 0.3 Correction — `notification_queue` is not the exposure the assessment claimed

`backend-centric-architecture-assessment.md` §7 listed this as a critical
RLS-disabled exposure. Verified empirically by switching roles inside the live
database:

```
anon SELECT           → BLOCKED: permission denied for table notification_queue
authenticated SELECT  → BLOCKED: permission denied for table notification_queue
```

RLS is indeed disabled, but the table carries **zero** anon/authenticated grants,
so PostgREST denies access by grant. Supabase's advisor flags it on
`relrowsecurity` alone and does not check grants, which is why its wording
("fully exposed") overstates the case here. It remains worth cleaning up as
defence-in-depth — a future `GRANT` would silently open it — but it is a dead
legacy table (125 rows, drained by an Edge Function that is now a no-op stub),
not a live exposure. Severity: low, cleanup.

### 0.4 P1 — `/providers/*` can redirect a payout destination, but the subsystem is orphaned

`providers.controller.ts:9-31` documents the flaw in its own words: `providers.id`
has no owner column, so `@Auth()` proves *who is calling* but not that they own
the provider record they named. `POST /providers/change-payout` writes the new
number first (`providers.service.ts:114-117`) and *then* sends the OTP **to that
new number** (`:131`) — so a caller who knows a provider UUID could redirect
payouts to their own phone and verify it themselves.

Verified contained: the Flutter app makes **no calls to `/providers/*`** (grep
across `mobile-app/lib` returns only unrelated local `providers/` imports), and
`providers.phone_payout` is written by this module and **read by nothing** in the
B2C payout path — the live payout flow resolves through `payout_destinations`.
So it is a real hole with no current financial reach.

Recommendation: **delete the module or add the owner column.** Leaving a
documented authorization hole in the tree because it is currently unreachable is
how it gets wired up by accident later. Also note `providers.service.ts:151` —
SMS delivery is a `TODO`, so today the OTP is only written to the server log.

### 0.5 Verified safe (checked, no action needed)

Two things the audit specifically went looking for and found already handled:

- **The plaintext bootstrap admin token** (`help24-super-admin-CHANGE-ME`,
  `admin-auth.service.ts:17`, seeded by migrations 045/052) is present in
  `admin_users` but **`active = false`** — the intended hardened state. Verified
  by hashing the literal and comparing against the stored `token_hash`.
- **Feed settings seed drift.** `090_feed_settings.sql` seeds `weights` without
  `staleness` and `urgency` without `enumHalfLifeHours`; `096` patches both. A
  database seeded from 090 alone would silently lose the staleness penalty and
  let a five-month-old "urgent" post keep a flat boost. **Production is correct**
  — the live rows contain `staleness: -22` and `enumHalfLifeHours: 72` — but the
  hazard is real for any new environment seeded from 090.

One operational note, not a defect: **three active `super_admin` accounts**
exist, two of which have not logged in since June and July respectively. Standing
financial authority that is not exercised is worth reviewing.

---

## 1. What is already remotely configurable (verified in production)

Before proposing anything, here is what does **not** need work. Queried live:

| Surface | Keys live in production | Reaches |
|---|---|---|
| `feed_settings` | 13 rows: `weights`, `distance`, `urgency`, `freshness`, `staleness`, `engagement`, `behaviour`, `availability`, `reliability`, `trust`, `time_of_day`, `diversity`, `retrieval` | The **entire** Discover ranking engine |
| `promotion_settings` | 3 rows: `serving`, `moderation`, `payment` | Sponsored slot caps and cadence, auto-approve, awaiting-payment TTL |
| `promotion_packages` | 4 rows | Promotion pricing and durations, editable via `PATCH /admin/promotions/packages/:id` |
| `app_settings` *(new)* | 6 rows: 4 kill switches, maintenance, min-version, announcement, payment poll tuning, urgent window | Client behaviour without an APK |
| `locations`, `professions`, `profession_categories`, `categories` + `registry_versions` | 479 / 482 / 34 / 32 rows | Reference vocabulary, synced to installed apps within 24 h |

**This is a large amount of already-correct work.** Every feed ranking weight,
decay curve, diversity cap and retrieval limit is already a SQL edit away from
changing, with a 60-second propagation and a compiled-defaults floor. The
roadmap below deliberately does **not** revisit any of it.

**One caveat that materially reduces its usefulness: there is no admin API or
dashboard for `feed_settings`.** `FeedController` exposes only `/feed`,
`/feed/interactions` and `/feed/availability`, and `backend/src/admin/**`
contains no feed routes. Every value above is tunable *only by raw SQL against
Supabase*. Promotions, by contrast, do have an admin surface
(`promotions-admin.controller.ts:142,153`), and the new `app_settings` has one
(`/admin/config`). Giving `feed_settings` the same treatment is a small, low-risk
piece of work with disproportionate operational value — it is the difference
between "a founder with a SQL console can tune ranking" and "the team can".

The gap is not the feed's *tunability*. The gaps are: no admin surface for it,
a set of ranking levers that were left out of the settings table, money rules,
background operations, security policy, and roughly a hundred client constants.

---

## 2. Method — how each candidate was judged

Four questions, in order. A candidate only becomes a recommendation if it passes
all four.

1. **Would changing this today require a deploy or an APK?** If not, it is
   already solved; skip it.
2. **Is it a policy or an invariant?** A policy is a choice a reasonable person
   could make differently next quarter. An invariant is a correctness property —
   "money moves at most once", "a caller may only approve their own job". Only
   policies are candidates. Invariants stay in code, with tests and review.
3. **Does remote control weaken anything?** Specifically: security, latency,
   offline capability, battery, startup speed, or operational blast radius. A
   remotely-editable authorization boundary is a privilege-escalation surface,
   not a feature.
4. **Is there a real operational scenario?** "Someone would actually change this,
   under time pressure, and be glad they could." If no such scenario exists, the
   value of moving it is zero and the cost is a new failure mode.

Question 3 is where most candidates die, and question 4 is where most of the
remainder die. The roadmap is deliberately shorter than the candidate list.

---

## 3. Group N — Never migrate (native platform boundaries)

These depend on device hardware or OS-owned consent. A server can receive their
output; it can never produce it.

| Capability | Plugin / API | Why it can never be server-side |
|---|---|---|
| GPS acquisition | `geolocator` — `location_service.dart:190-272` | The GNSS chip is in the handset |
| Location permission + OS location toggle | `permission_handler` — `location_service.dart:84-111` | The consent dialog is OS-owned and bound to the app's UID |
| Foreground location service (journey sharing) | `location_service.dart:438-464`, manifest `:28-30` | The only legal way for a backgrounded Android app to keep receiving fixes |
| FCM token acquisition/refresh | `notification_service.dart:443`, `:461-469` | Minted by Play Services for this installation |
| Notification permission (Android 13+) | manifest `:5` | OS-owned consent |
| Notification channel creation | `MainActivity.kt:17-44`, `notification_service.dart:90-97` | Registered in the system NotificationManager; a server can only *name* a channel |
| FCM background isolate + MessagingStyle | `notification_service.dart:108-267` | A separate isolate spawned when the process is dead; the only place a device-local chat mute can suppress a push |
| Cross-isolate prefs | `notification_service.dart:43` | Readable with no network and no main isolate — that is the point |
| Image pick + native downscale | `image_picker` — six call sites | The photo library and camera are OS-owned; recompression happens before bytes leave |
| File picking | `file_picker` | SAF / document providers |
| Biometrics | `local_auth` — `profile_screen.dart:1196-1223`; requires `FlutterFragmentActivity` (`MainActivity.kt:11`) | Sensor + secure enclave |
| Google Sign-In | `google_sign_in` | Reads on-device accounts |
| Phone auth + Play Integrity + SMS auto-retrieval | `auth_service.dart:324-355` | Attests *this binary on this device*; worthless if evaluated server-side |
| Maps SDK rendering | `google_maps_flutter` | Native view. Note the deliberate key split: Maps key is client-side (lockable to package+SHA-1), Routes key is server-side (not lockable) |
| In-app browser / WebView | `url_launcher`, `webview_flutter` | OS components |
| Connectivity state | `connectivity_plus` | A server can never tell a client it is offline |
| Installed app version | `package_info_plus` — `remote_config_service.dart:169` | The running binary's own version; it is the *input* to the server-owned gate |
| Firestore offline persistence | `app_firebase.dart:35-38` | An on-device mirror *is* the feature |
| System UI chrome, haptics, reduced-motion | various | Platform surfaces |
| Transport security policy | manifest `:36-37`, `network_security_config.xml` | Enforced by the OS before a request leaves |
| App lifecycle observation | `journey_engine.dart:227-242` | Used to heal a stream Android killed under Doze — only the client can observe that |

### 3.1 The important nuance: policy wearing a native costume

Several values *look* native because they operate on sensor output, but are
editorial judgements. These are **not** Group N; they appear in the roadmap:

| Value | Location | Why it is policy |
|---|---|---|
| 50 m / 150 m accuracy gates | `location_service.dart:148,154` | The sensor reports accuracy; deciding 151 m is unusable is a product call about ranking quality |
| 45 s fix staleness | `location_service.dart:166` | A judgement about how fast users move |
| Journey geofences (100/120/300/360 m, 75 m good-fix) | `journey_engine.dart:248-262` | Geometry policy applied to sensor output |
| Arrival dwell 60 s / 120 s | `journey_engine.dart:250,254` | A confidence policy |
| 2 h journey safety cap | `journey_engine.dart:245` | A privacy decision with no hardware relationship |
| Name-plausibility radii 1.0 / 3.5 / 25 km | `current_location_service.dart:198,202,209` | Kenyan-geography heuristics — tuned against Kisauni-vs-Nyali specifically. The most locale-specific number in the app |
| Image resize 1200/1024/512 px, q85 | six call sites | Bandwidth policy on metered connections |

One genuine borderline case: **on-device reverse geocoding**
(`location_service.dart:321`, `place_name_cache.dart:64`) is a pure
`(lat,lng) → name` function that a backend *could* serve. It stays client-side
for economics and offline resilience, not physics — `place_name_cache.dart:20-22`
states this explicitly ("NOT the billable Google Geocoding API"). Keep it, but
know it is a choice, not a constraint.

---

## 4. Group K — Keep in code permanently (invariants, not knobs)

Passing question 1 but failing question 2 or 3. Listed because "why is this not
configurable?" deserves an answer as much as the opposite.

| Item | Location | Why it must not be remotely editable |
|---|---|---|
| `calculateFee` / `calculateTotal` logic and rounding | `mpesa/fee.ts:11-23` | The *tiers* are data (see H2); the arithmetic, rounding and refusal below minimum are correctness properties |
| Escrow / transaction state transitions | `mpesa.service.ts:754-916` | Money moves at most once. The DB CHECKs constrain the *set* of statuses, not transitions; the transition legality lives only here |
| Release source-state gate | `mpesa.service.ts:504` | What makes a double payout a 409 instead of a second B2C call |
| Reconcile: settle only on a confirmed result, never on elapsed time | `mpesa.service.ts:741-742,1025-1030` | Paying out on a timeout is how money is lost twice |
| Payout destination resolution; `STRONGLY_VERIFIED_METHODS` | `payout-destination.resolver.ts:56-59,179-232` | A trust definition. A remote edit silently lowers the bar on every payout in flight |
| Audit `emitOrThrow`-before / `emit`-after ordering | `payout-audit.service.ts:88-113` | The forensic trail's integrity depends on the ordering |
| Dispute role gates (`senior_admin` for financial rulings) | `decisions.service.ts:70-72` | An authorization boundary. Remotely editable authorization is a privilege-escalation surface |
| Dispute split math and post-settlement block | `decisions.service.ts:292-324,99-103` | Correctness |
| Review eligibility conditions | `reviews.service.ts:152-178` | Integrity conditions, all cheap, all server-evaluated |
| Campaign transition table | `campaign-state.ts:32-42` | Correctness |
| Production hard-blocks on dev endpoints | `mpesa.service.ts:82-84,350-354,1128-1132,1164-1168` | The block is the safety property |
| `FeedArrival.installs` — the in-app interruption policy | `feed_snapshot.dart:362-379` | Seven ordered rules, a pure function, fully tested. A contract, not a tunable |
| Notification tap → screen routing table | `main.dart:383-472` | Maps to *screen classes* that only exist in the binary. A server cannot name a screen that has not shipped. The `default` case is already the correct forward-compatibility hatch |
| Single 401 replay | `api_client.dart:190`, `http_client_with_token.dart:83` | Correctly single-shot; a configurable retry count here invites a storm |
| Telemetry: zero retries by design | `interaction_tracker.dart:202-206` | Re-queueing would skew affinity |

---

## 5. The roadmap

Phases are ordered by (operational value ÷ deployment risk). Each is internally
coherent and independently shippable, and each ends in a state where stopping is
a reasonable decision.

**A note on what "configurable" means per phase.** Phases 2–3 add *server-side*
config, which takes effect on the next backend read — no client involvement, so
no APK and no compatibility surface. Phase 4 extends the *client* contract, which
means old APKs keep their compiled defaults and only new builds honour new keys.
That asymmetry is why the server-side work comes first.

---

### Phase 2 — Operational safety and the money-adjacent knobs

*Low risk. Backend only. No client changes, no schema changes.*

The theme: things an operator would reach for during an incident, plus the two
already-identified defects that make the background system unreliable.

| # | Item | Current | Location | Why |
|---|---|---|---|---|
| 2.1 | **Fix the escrow repair upsert** | broken since written | `event-processor.service.ts:226` | §0.1. Not config — a defect. Needs a unique constraint on `escrow.transaction_id` (a migration, so it stops for approval) or a select-then-insert |
| 2.2 | **Decide `AUTH_ENFORCEMENT`** | monitor/off | env | §0.2. Read `authWouldDeny` from production logs, then flip. No code change |
| 2.3 | Outbox retry interval + batch size | 60 s / 100 | `event-processor.service.ts:10`, `events.service.ts:149` | The only lever for draining a backlog faster during an incident |
| 2.4 | Outbox `MAX_RETRIES` | 3 | `event-processor.service.ts:11` | Fix the duplicate literal at `events.service.ts:145` first — two sources of truth for one number |
| 2.5 | **Outbox 24 h abandonment window** | 24 h | `events.service.ts:139` | Events older than 24 h are silently never retried *and never dead-lettered* — invisible to `deadLetterCount()`. This is a money-event loss path (`payment.payout_requested` is retried). Treat as a defect, not a knob |
| 2.6 | Dispute SLA window / interval / per-tick cap | 3 d / 30 min / 50 | `sla.service.ts:15,16,54` | Auto-escalation moves no money; it changes a status. Safe |
| 2.7 | Dispute anti-spam limit | 5 per 24 h | `disputes.service.ts:25-26` | Pure abuse control |
| 2.8 | Dispute auto-priority thresholds | 30k/15k/5k | `disputes.service.ts:781-786` | Only orders a queue |
| 2.9 | Promotions sweep interval + batch | 60 s / 100 | `promotions-sweep.service.ts:5`, `campaigns.service.ts:512,552` | Same reasoning as 2.3 |
| 2.10 | Promotion stale-pending STK window | 3 min | `promotion-payments.service.ts:49` | Only decides when a user may retry a prompt; late success is still honoured (`:261-294`) |
| 2.11 | Health snapshot interval + latency budgets | 15 s; 1/3/5 s | `health.service.ts:64`, `health.types.ts:71-75` | Probe tuning |

Also fold in, as defects rather than config:

- `sla.service.ts:17` — `awaiting_*_evidence` and `awaiting_admin_review` cases
  are never escalated. A case parked awaiting client evidence waits forever.
- `decisions.service.ts:400-409` — `notifySuperAdmins` only writes a log line.
  Escalations, including SLA auto-escalations, reach a human only by log
  inspection.
- `fn_prune_user_interactions` (migration `091:221-233`) **has no caller**. The
  documented 180-day retention on `user_interactions` is not enforced; the table
  grows unbounded. Either schedule it from an existing sweep or stop documenting
  a retention that does not happen.
- `promotion-payments.service.ts:387` — revenue summary silently truncates at
  10,000 paid rows.

**Risk:** low. Every item is a server-side value with a compiled default, using
the `AppConfigService` pattern already in production. **Offline impact:** none.
**Performance:** none — these are read once per sweep, not per request.

---

### Phase 2.5 — The ranking levers that were left out of `feed_settings`

*Low risk. Backend only. Additive keys to an existing, proven surface.*

Thirteen weights are tunable; a set of equally consequential numbers sitting
inside the same engine are not. They are hardcoded either in TypeScript (deploy)
or in SQL functions (migration). Each is a genuine product lever.

| # | Lever | Current | Location | Why it matters |
|---|---|---|---|---|
| 2.5.1 | **Profession match tiers** | exact `1.0`, group `0.55`, token `0.35` | `ranking/signals/profession-match.ts:24-27` | Profession is the **second-heaviest weight (25)**. How much an adjacent trade or a text-only mention is worth against an exact hit is pure product policy, and it has no settings key at all |
| 2.5.2 | **Promotion `rankScore` weights** | `0.5·rating + 0.3·completion + 0.2·proximity` | `promotions/serving-logic.ts:139` | The entire sponsored quality model. The organic feed has 13 tunable weights; the paid feed has three hardcoded ones |
| 2.5.3 | `ROTATION_POOL_FACTOR` | `3` | `serving-logic.ts:160` | Directly trades ad quality against exposure fairness among equal payers |
| 2.5.4 | Diversity `CONSTRAINT_COST` | category 1, type 2, author 4, pageCap 8 | `ranking/diversity.ts:62-67` | The powers-of-two ordering *is* the anti-spam guarantee (variety is always sacrificed before author capping). The caps are tunable; the priority order is not |
| 2.5.5 | Affinity retrieval threshold | `0.2` | `feed.service.ts:330` | Decides how wide behavioural retrieval reaches |
| 2.5.6 | Availability bucket **boundaries** | `24 h`, `7 d` | `signals/availability.signal.ts:46-47` | The four availability *scores* are tunable; the windows they attach to are not |
| 2.5.7 | `RELIABILITY_NEUTRAL` | `0.5` | `signals/reliability.signal.ts:5` | What "no track record" is worth |
| 2.5.8 | Secondary-skill default weight | `0.7` | `viewer-context.service.ts:217` | What an unweighted `user_skills` row counts for |
| 2.5.9 | Promotion proximity model | linear `1 − min(d,R)/R` | `serving-logic.ts:138` | Diverges from the organic engine's rational decay `1/(1+(d/15)^1.5)` — same concept, two curves |
| 2.5.10 | `FeedSettingsService` cache TTL | `60 s` | `feed-settings.service.ts:25` | The tuning loop's own feedback latency — the one number a tuner cannot tune |

**Migration-locked (SQL) levers** — same category, higher change cost:

| # | Lever | Current | Location |
|---|---|---|---|
| 2.5.11 | **Reputation tier thresholds** | `trusted_professional`: ≥10 reviews, ≥50 jobs, ≥4.8 bayes, ≤3% disputes, ≥95% completion (and three more tiers) | migration `055:136-145` |
| 2.5.12 | Bayesian prior `C = 10.0`, `m = 4.5` | | migration `055:53-54` |
| 2.5.13 | Pool ordering `created_at DESC` before the 150-row LIMIT | | migration `095:159,169,190` |
| 2.5.14 | Cap tiebreak `pool_count DESC, created_at DESC` | | migration `095:214-219` |

2.5.11 is the sharpest illustration of the split: the tier *scores* live in
`feed_settings.trust.tierScores` and change with a SQL update, while the tier
*boundaries* that decide who gets each tier require a migration. 2.5.13 is
quietly important — it bounds what the ranker can ever see, so a saturated pool
means the older-but-better candidate is never scored at all.

**Also worth fixing here (a correctness divergence, not a knob):** a provider
with zero reviews is treated as **neutral (0.5)** by the organic feed
(`reliability.signal.ts:41-42`) but as **worst (0)** by promotion ranking
(`serving.service.ts:158` reads `?? 0` against `055:77`, which returns
`bayesian = 0` when `n = 0`). Organic ranking protects new providers; paid
ranking punishes them. One of the two is wrong.

---

### Phase 2.6 — Search

*Medium risk, high product value. Backend + SQL. Called out separately because
it is the largest single product gap the audit found.*

**The current query contributes nothing to ranking.** `ViewerContext`
(`ranking/types.ts:88-125`) has no field for the live search string, and no
signal reads one. A search is a hard *retrieval filter* only
(`095:145-148`, a single substring `ILIKE` across `title | description |
category`); results are then ordered by the general Discover model — distance 30,
profession 25, urgency 18. **A post whose title exactly matches what the user
typed ranks below a nearer post that merely mentions the word in its
description.** The `searchHistory` signal (weight 6) scores *past* queries, not
the current one.

This cannot be expressed in `feed_settings` at all: there is no `queryMatch`
signal to weight. It needs a new signal (deploy) plus a new settings key.

**Compounding it, the same typed string is matched five different ways:**

| Surface | Semantics | Location |
|---|---|---|
| Ranked feed | one substring, 3 columns | `095:145-148` |
| Promotion serving | **AND across tokens**, 3 columns | `serving-logic.ts:80-86` |
| Discover fallback (backend down) | substring, 3 columns | `post_service.dart:198-201` |
| Jobs fallback | substring, **2 columns — no category** | `post_service.dart:322-325` |
| Jobs screen, post-fetch | local filter over `title/company/location` | `jobs_screen.dart:99-109` |

Also: `094_feed_indexes.sql` creates trigram indexes on `title`, `description`
and `location` but **not** on `category`, while `095:148` filters on
`category ILIKE` — so every search forces a scan on that predicate.

Recommendation: treat search as its own small project. Add a `queryMatch` signal
with a `feed_settings` weight, unify the matcher, and add the missing index.

---

### Phase 3 — Server-side cost and correctness levers

*Low-medium risk. Backend only. One item touches money display and needs care.*

| # | Item | Current | Location | Why |
|---|---|---|---|---|
| 3.1 | **Serve the fee tiers + minimum as data** | compiled in both TS and Dart | `fee.ts:3-14`, `payment_utils.dart:3-26` | The tables are hand-mirrored, already **divergent** (Dart returns 0 below 100 where TS throws), and have **no parity test**. Serving the data — with the compiled table as the client fallback, exactly the pattern promotion packages already use via snapshot-at-purchase — removes the app-store coupling. The *calculation* stays in code (Group K) |
| 3.2 | Payout rollout flags | env vars | `payout-destinations.service.ts:50,57-58,66-67` | `PAYOUT_DESTINATIONS_ENABLED`, `PAYOUT_ALLOW_LEGACY_FALLBACK`, `PAYOUT_REQUIRE_VERIFIED` are already flags but still need a restart. DB-backing them makes a payout rollout reversible in seconds |
| 3.3 | Google Routes cost dials | 250 m / 90 s / 45 s / 1500 m | `route_service.dart:77-80` | **Client-side today** — see Phase 4. Listed here because the *cost* is server-side (billable quota). Flagged now so the two phases are planned together |
| 3.4 | Package/settings cache TTLs | 60 s | `packages.service.ts:27`, `settings.service.ts:42`, `app-config.service.ts:37` | Lets an operator trade propagation speed against DB load during an incident |

**Risk on 3.1:** the fee is what a user is *told* they will pay. The server
already recomputes the real charge on initiate (`mpesa.service.ts:150-154`), so a
stale client fee is a display bug, not a billing bug — but it is a trust-damaging
one. Ship the served tiers behind a version check and keep the compiled table as
the fallback rung.

---

### Phase 4 — Client operational constants

*Medium risk. Requires an APK, so old clients keep compiled defaults forever.*

This is the largest group and the one with the most careful selection. Roughly a
hundred client constants were catalogued; these are the ones that pass question 4.

**4a — Startup and latency budgets (highest value)**

| Item | Current | Location |
|---|---|---|
| **Splash hold deadline** | 3000 ms | `launch_sequence.dart:63` |
| Ranking patience before the chronological stand-in | 2600 ms | `app_provider.dart:583` |
| Viewer grace before first ranking | 900 ms | `app_provider.dart:129` |
| Firebase persistence restore wait | 1500 ms | `startup_prefetch.dart:51` |

The splash deadline is the single highest-value client constant in the app. Its
own comment (`launch_sequence.dart:53-62`) records that it was **already raised
once, from 2200 ms, because the ranking backend sleeps when idle** — a client
constant compensating for a server property, changeable only by a Play release.
Note also that 4a's first two values are coupled (patience must stay below the
deadline or it never fires) and **nothing enforces that** — serve them as one
document and validate the relationship server-side.

**4b — Network timeout policy**

Fifteen distinct timeout values spanning 5–30 s, with no shared policy and, with
one exception (`notification_store.dart:110-112`), no stated rationale. On the
mobile-data connections this product targets these are the difference between a
slow screen and a broken one, and there is no single place to widen them during
an incident. Recommend one served `client.timeouts` document with per-surface
keys and the current values as defaults.

**4c — Billable and battery dials**

| Item | Current | Location |
|---|---|---|
| Route refresh distance/interval/near-threshold | 250 m / 90 s / 45 s / 1500 m | `route_service.dart:77-80` |
| Route cache TTL | 45 s | `route_service.dart:64` |
| Journey route-fetch backoff | 30 s → ×2 → 5 min | `journey_engine.dart:282-284` |
| Journey position stream interval | 8 s | `location_service.dart:444` |
| Presence heartbeat | 60 s | `home_screen.dart:44` |
| Conversation poll (pre/post realtime) | 15 s → 60 s | `chat_service_supabase.dart:234,293` |
| Profile + settings watchers | 15 s each | `user_profile_service.dart:218,561` |
| Job status poll | 30 s | `job_status_card.dart:132` |

These are the direct Google Routes billing lever and the app's largest sources of
background requests and radio wake-ups.

**4d — Values that mirror server-owned constants (drift risks)**

| Item | Current | Location | Mirrors |
|---|---|---|---|
| Feed snapshot TTL | 10 min | `feed_snapshot.dart:141` | The server's ranking rotation bucket (`retrieval.rotationBucketMinutes`, live value 10) |
| Significant-move threshold | 1.0 km | `feed_snapshot.dart:464`, `location_provider.dart:43` | The server's distance-decay curve (`distance.halfPointKm` = 15, steepness 1.5) |
| Sponsored cadence fallbacks | 7 / 8 | `promotion_models.dart:208,213-215` | `promotion_settings.serving` |

Each is a client constant explicitly documented as matching a server value that
is *already* DB-tunable. Change the server today and the client silently
disagrees. These should be served, not mirrored.

**4e — Bandwidth and media**

Image dimensions and quality at six call sites (1200/1024/512 px, q85), the
Firestore disk cache (100 MB, `app_firebase.dart:37`), and the storage
`cacheControl` header (3600 s on immutable UUID-named objects — could be a year).

**4f — Client-side location policy** (the §3.1 list): accuracy gates, staleness,
journey geofences, dwell, safety cap, name-plausibility radii.

**Defects to fix alongside 4e/4f, not configure:**

- `image_composer_screen.dart:64` and `messages_screen.dart:1384` set `maxWidth`
  without `maxHeight`, unlike the sibling call in `post_screen.dart:298-300` — a
  tall panorama is unbounded on one axis.
- `notification_service.dart:201` uses `String.hashCode` as a notification id.
  Dart's string hash is not stable across releases; two chats can collide and one
  notification silently replaces the other's.
- `journey_engine.dart:811,737,624` leave three real tunables as inline literals
  in a file whose own "single source of truth" tunables block sits at `:244-264`.
- `post_service.dart:249` — `fetchUrgentPosts` defaults to `limit: 5` while every
  real caller passes 20.
- `storage_service.dart:150-163` — multi-image upload swallows per-image failures
  to a `print`; the user gets a partial post with no indication which image was
  lost.

---

### Phase 5 — Copy and the localisation question

*Deliberately last, and deliberately small. The honest recommendation here is
"mostly don't".*

The mechanism is sound: `assets/l10n/{en,sw}.json` loaded through
`app_localizations.dart:64,101`, with an `InheritedWidget` above `MaterialApp`.
Swapping the asset read for a cached HTTP fetch — bundled JSON as the fallback
rung, the same three-stage pattern as `ReferenceRegistry` and
`RemoteConfigService` — would be a contained change.

**But the catalogue is 39 keys across 17 call sites, against 201 hardcoded
`Text('…')` literals in `lib/`.** Localisation is ~2% adopted. Making delivery
server-driven today buys remote control over 39 strings while 201 remain
compiled in. **The bottleneck is extraction, not delivery.** Do the extraction
first, or do neither.

Two related notes:

- `app_localizations.dart:18` falls back to `_strings[key] ?? key`, so a partial
  server response would print raw keys to users. Before any remote path, that
  fallback must become "bundled English".
- **Error copy is where the value actually is.** 60 distinct message literals
  across `error_mapper.dart` and `auth_error_mapper.dart`, all English, all
  release-gated. This is the surface where a wrong message costs the most —
  `auth_error_mapper.dart` exists precisely because Firebase's own copy ("Play
  Integrity checks and reCAPTCHA checks were unsuccessful") reached real users.
  If any copy becomes server-driven, start here, not with the 39-key bundle.

---

### Phase 6 — Multi-country readiness (a data-model project, not a config project)

The brief asked to optimise for Help24 across multiple countries, payment
providers and currencies. The audit's answer is blunt: **remote configuration
will not get you there, and treating it as a config problem would waste the
phase.**

| Assumption | Location |
|---|---|
| `PayoutChannel = 'mpesa'` — a single-value union type | `payout-destination.resolver.ts:23` |
| Daraja base URLs and all four API paths | `daraja.service.ts:5-13` |
| MSISDN canonical form `254` + 9 digits, hardcoded regex | `common/phone/msisdn.ts:23,33-39`, deliberately mirrored in SQL |
| `country DEFAULT 'KE'` | migration `104:139` |
| **No currency field exists** on `transactions`, `escrow`, `dispute_decisions`, or any `promotion_*` table | all schemas |
| Currency baked into **column names**: `price_kes`, `amount_kes` | migration `077:52,118` |
| Amounts are integer KES with no minor units | `mpesa.service.ts:148` |
| "KES" hardcoded in ~15 client sites and ~6 server sites | `format_utils.dart:22,36` et al |

The one part already designed for expansion is the payout-destinations layer: its
fingerprint is keyed on `channel|country|normalized` (migration `104:105-120`).
Everything upstream assumes KES and M-Pesa.

Adding a second country is a schema migration (currency column, minor units), a
provider abstraction behind `DarajaService`, and a copy sweep. Sequence it as its
own project **after** Phase 4, and do not let the config plane create the
illusion it is closer than it is.

---

## 5b. Security — the red lines, stated explicitly

The brief asked for security policies to be evaluated as configuration
candidates. Most of them must **not** be, and saying so precisely is more useful
than a list of knobs. Making any of these DB- or `/config`-driven converts a
single row write, or one compromised response, into an authentication bypass.

| # | Value | Location | Why it must stay env/code |
|---|---|---|---|
| 1 | **`AUTH_ENFORCEMENT`** | `auth.config.ts:38` | One string decides whether a forged `body.user_id` is honoured platform-wide. Env + restart is the correct blast radius: it needs infrastructure credentials and cannot be flipped by an app-layer compromise |
| 2 | **`AUTH_ENFORCE_ONLY`** | `auth.config.ts:39` | An enforcement-*narrowing* allowlist — setting it removes protection from every route not listed. (Guard rail already exists: setting it outside `enforce` mode fails the boot) |
| 3 | **`CACHE_TTL_CEILING_MS = 15 min`** | `auth.config.ts:35` | The env var can only ever *lower* the identity-cache TTL. If the ceiling itself were configurable, a 30-day identity cache becomes one edit away |
| 4 | Dual expiry: cache entry dies at `min(TTL, token.exp)` | `token-verifier.service.ts:178` | Guarantees a cached identity cannot outlive its credential even if #3 were misconfigured |
| 5 | **Payout OTP expiry (5 min) and 6-digit entropy** | `providers.service.ts:135-136` | The two terms in the brute-force equation. The published safety maths in `rate-limit.policies.ts:496-508` ("~0.03% chance of hitting a live code") is only true at 5 minutes |
| 6 | **`PAYOUT_REQUIRE_VERIFIED`** | `payout-destinations.service.ts:66-67` | Gates whether an unverified destination can receive money. **Currently defaults to `false`** — turning it on is the hardening step, and a DB flip back to `false` must not be possible |
| 7 | Password minimums (users 8, admins 8) | `auth_service.dart:984`, `admin-invites.service.ts:212-214` | A remotely-lowerable password floor is a credential-strength kill switch |
| 8 | **Identity-binding declarations** | `identity-binding.ts:35-43` | `SelectProviderDto` carries both `client_user_id` (the caller) and `provider_id` (the person being selected). Binding the wrong one lets a caller assign a job to themselves. A code-review artifact, never config |
| 9 | **`otp:verify` and `admin:auth` rate limits** | `rate-limit.policies.ts:495-519,542-557` | These are the *only* brute-force ceilings on a 6-digit payout code and on the admin-invite validity oracle — there is no account lockout anywhere (see below) |
| 10 | Every RLS `USING`/`WITH CHECK` predicate, and the `087`/`098`/`104` triggers | migrations | A migration is the right change control for an ownership boundary; a settings row is not |
| 11 | `ADMIN_DASHBOARD_URL` | `admin-invites.service.ts:69` | Controls where every admin invite link points — an attacker-controlled value redirects them to a phishing page |

**The pattern to copy when something security-adjacent *should* be tunable** is
already in the tree twice: `app-config.service.ts:164-167` clamps every remote
numeric in code, and migration `104:319` makes payout OTP `max_attempts`
per-row configurable behind a `CHECK (max_attempts BETWEEN 1 AND 10)`. Data
configurable, ceiling in schema. That is the right shape.

### Three security gaps that configuration cannot fix

1. **There is no account lockout of any kind, anywhere.** A repo-wide search for
   lockout/failed-attempt/login-attempt patterns returns nothing. Password brute
   force is bounded only by Firebase's own throttling; admin bearer tokens are
   bounded only by the `admin:auth` IP limit; payout OTP wrong-guesses are
   bounded only by `otp:verify`. `users.is_banned` exists but is a manual ban.
2. **Admin tokens never expire.** `authenticate()` checks only hash match and
   `active === true`; rotation is manual. Mitigated by 256-bit entropy, but an
   admin token, once leaked, is valid forever.
3. **An unknown rate-limit policy name silently downgrades to `default`**
   (`rate-limit.service.ts:84-88`) rather than failing the boot like every other
   catalogue error. A typo in `@RateLimit('otp:verfy')` would quietly raise the
   OTP brute-force ceiling from 5-per-15-min to 120-per-min, with no signal.

Also verify, since it cannot be read from this repo: **`ADMIN_AUTH_DEBUG` must
not be set in production.** It is `=1` in the local `.env`, and it un-hides
`GET /admin/_diag`, which returns a token hash prefix plus the matching admin's
email and role (`admin-invites-public.controller.ts:72-80`).

---

## 6. Prioritisation summary

| Phase | Theme | Risk | Needs APK? | Needs migration? |
|---|---|---|---|---|
| **0 (now)** | Escrow repair defect; auth enforcement decision | — | No | Likely (2.1) — stops for approval |
| **2** | Operational safety + background knobs | Low | No | No |
| **2.5** | Ranking levers omitted from `feed_settings`; admin surface for it | Low | No | Only 2.5.11–2.5.14 |
| **2.6** | Search: a `queryMatch` signal, one matcher, the missing index | Med | Partly (fallbacks) | Yes (index) |
| **3** | Cost and correctness levers, fee tiers as data | Low-med | No | No |
| **4** | Client constants: startup, timeouts, billable dials, drift mirrors | Medium | **Yes** | No |
| **5** | Copy / localisation | Low | Yes | No |
| **6** | Multi-country | High | Yes | **Yes, substantial** |

If only one phase is done: **Phase 2**. If two: add **2.5**, and give
`feed_settings` an admin endpoint while you are in there — it is the single
cheapest multiplier on work that already exists.

Against the stated optimisation targets:

- **Operational agility** — Phases 2 and 3 deliver most of it with zero client risk.
- **Deployment risk** — Phases 2 and 3 are backend-only with compiled defaults.
- **No Flutter updates unless unavoidable** — Phase 4 is the only APK-requiring
  phase, which is why it is third rather than first.
- **Offline behaviour** — preserved throughout: every client value keeps its
  compiled default as the floor, and no phase adds a launch-time network dependency.
- **Native performance / battery** — Phase 4c exists specifically to make battery
  and billing dials adjustable rather than fixed.
- **Security** — improved by §0.2, and deliberately *not* touched by anything
  else: no authorization boundary, no verification rule, and no money-movement
  gate appears anywhere in this roadmap as a configuration candidate.
- **Startup speed** — Phase 4a is the direct lever, and the config plane itself
  was built never to touch the launch transaction.

---

## 7. Defect register (found during this audit, not config work)

Ordered by severity. None have been fixed.

| # | Severity | Defect | Location |
|---|---|---|---|
| 1 | **P0** | Escrow repair upsert targets a non-existent unique constraint; 6 funded txs (KES 24,895) have no escrow row | `event-processor.service.ts:226` |
| 2 | **P0** | `@Auth` routes served without credentials in production — enforcement never flipped | env / `auth.config.ts:38` |
| 3 | P1 | Outbox events older than 24 h are silently abandoned, uncounted, including payout events | `events.service.ts:139` |
| 4 | P1 | `notifySuperAdmins` only logs — escalations reach no human | `decisions.service.ts:400-409` |
| 5 | P1 | SLA sweep never escalates `awaiting_*_evidence` / `awaiting_admin_review` cases | `sla.service.ts:17` |
| 6 | P2 | Fee tables diverge below KES 100 (Dart returns 0, TS throws); no parity test | `payment_utils.dart:20` vs `fee.ts:12` |
| 7 | P2 | `fn_prune_user_interactions` has no caller; documented 180-day retention not enforced | migration `091:221-233` |
| 8 | P2 | Dispute split validated with `>` not `≠` — an under-allocated split silently retains the remainder | `decisions.service.ts:297` |
| 9 | P2 | Notification id from `String.hashCode` — unstable, can collide | `notification_service.dart:201` |
| 10 | P3 | Revenue summary truncates at 10,000 rows | `promotion-payments.service.ts:387` |
| 11 | P3 | `MAX_RETRIES` duplicated as a literal `3` | `events.service.ts:145` |
| 12 | P3 | Chat image picks set `maxWidth` without `maxHeight` | `image_composer_screen.dart:64`, `messages_screen.dart:1384` |
| 13 | P3 | Multi-image upload swallows per-image failures | `storage_service.dart:150-163` |
| 14 | P3 | `fetchUrgentPosts` default `limit: 5` vs 20 at every call site | `post_service.dart:249` |
| 15 | P3 | No App Links / `VIEW` intent-filter; `AppUrls.authContinueUrl` has no receiver | `AndroidManifest.xml:50-53` |
| 16 | Low | `notification_queue`: RLS off (grants revoked, so not exposed); dead legacy table | live catalog |
| 17 | **P1** | `/providers/*` allows redirecting a payout destination without an ownership check; contained only because the module is orphaned. Its OTP is also never sent (SMS is a `TODO`) | `providers.controller.ts:9-31`, `providers.service.ts:114-131,151` |
| 18 | **P1** | No account lockout anywhere — password, admin token, or payout OTP | repo-wide |
| 19 | **P1** | Unknown `@RateLimit` policy name silently falls back to `default` instead of failing the boot; a typo would raise the OTP ceiling from 5/15min to 120/min | `rate-limit.service.ts:84-88` |
| 20 | P1 | Admin bearer tokens never expire; rotation is manual only | `admin-auth.service.ts:210-271` |
| 21 | P2 | Zero-review providers: neutral (0.5) in organic ranking, worst (0) in promotion ranking | `reliability.signal.ts:41-42` vs `serving.service.ts:158` |
| 22 | P2 | `090_feed_settings.sql` seed omits `weights.staleness` and `urgency.enumHalfLifeHours` (096 patches; production verified correct, but a fresh seed from 090 is wrong) | migration `090:50-65,80-83` |
| 23 | P2 | No trigram index on `posts.category`, yet every search filters on `category ILIKE` | `094_feed_indexes.sql` vs `095:148` |
| 24 | P2 | Two coexisting phone validators with different strictness; the money path uses the looser one | `phone_utils.dart:10-26` vs `kenyan_phone.dart:30-38` |
| 25 | P3 | `payout_destination_verifications.expires_at` has no maximum-TTL CHECK, unlike `max_attempts` which is correctly bounded 1–10 | migration `104:303,317,319` |
| 26 | Ops | Three active `super_admin` accounts, two unused since June/July | `admin_users` |
| 27 | Ops | Verify `ADMIN_AUTH_DEBUG` is unset in production — it un-hides `/admin/_diag`, which returns an admin's email and role | `admin-invites-public.controller.ts:52-80` |

---

## 8. What I recommend you decide first

**Immediate, before any phase:**

1. **The escrow defect (§0.1).** The only item here touching money integrity.
   The fix is a unique constraint on `escrow.transaction_id` plus a corrective
   backfill of six rows — both are production writes and both stop for your
   explicit approval. I have written neither.
2. **Auth enforcement (§0.2).** Read the `authWouldDeny` counter from production
   access logs, then decide whether to flip `AUTH_ENFORCEMENT=enforce`. No code
   change; a real posture change. Flipping it blind would sign users out
   mid-flow, which is why the number comes first.
3. **Two things I cannot check from the repo:** confirm `ADMIN_AUTH_DEBUG` is
   unset in production (§5b), and review the three standing `super_admin`
   accounts (§0.5).

**Then, on phases:**

4. **Phase 2** is the recommended start — low risk, backend-only, compiled
   defaults throughout, and it makes the background system observable and
   drainable during an incident. It also carries four latent defects worth
   fixing on the way through (the 24 h outbox window, the never-escalated
   dispute states, `notifySuperAdmins` notifying nobody, and the retention
   function with no caller).
5. **Phase 2.5** if you want the highest value per unit of risk after that,
   *including* giving `feed_settings` an admin endpoint. The ranking engine is
   already fully tunable and effectively unreachable by anyone without a SQL
   console; that is a cheap thing to fix.
6. **Phase 2.6 (search)** is the largest product opportunity in this document —
   an exact title match currently loses to a nearer post that merely mentions the
   word. It is also the only phase whose value is user-visible rather than
   operational. Sequence it by product priority, not by risk.

I have not written code for any of this. No phase should begin until you have
reviewed and chosen.
