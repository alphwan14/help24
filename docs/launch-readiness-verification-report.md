# Launch Readiness Verification Report

**Date:** 2026-08-08 (round 3 — push delivery proven, M4 closed, API 22 boundary established)
**Primary device:** Samsung **SM-G986U (Galaxy S20+ 5G)**, **Android 13**, **SDK 33**, **arm64-v8a**, build `TP1A.220624.014`, physical device over ADB (`R5CN218ZKZY`). No emulator.
**Compatibility-boundary device (round 3):** **OPPO X9009**, **Android 5.1**, **SDK 22**, arm64-v8a, physical device over ADB (`4PUGSC4PHUEYVC6T`).
**Round 1 device:** Samsung SM-A217F (Galaxy A21s), Android 12 / SDK 31 (`R58N624CD2J`) — where C1 and H1 were originally found.
**Build (round 3):** `flutter build apk --release` from commit `2416e32`, **68.8 MB**, installed via `adb install -r`. No dart-defines — `ApiConfig.baseUrl` resolved to the production default.
**Backend:** `help24-backend` (srv-d7mjm2v7f7vs73f8qaqg). Round 2 ran against deploy `dep-d9r6etrl550s73ddphug` (`5e5ea28`); round 3 fixes deployed as `dep-d9re7q37uimc73avrro0` (`2416e32`).
**Method:** every UI action driven by `adb input`, every screen captured by `adb exec-out screencap`, every backend claim correlated against Render logs by `requestId`, every OS claim taken from `dumpsys`. No claim below is made from code reading alone.

---

## Round 3 summary

Three things were asked for. All three were done, and doing them surfaced **one new critical security finding** and **two new real defects** that no amount of code reading had caught.

| Objective | Outcome |
|---|---|
| Prove a real push reaches the S20+ | ✅ **Proven** — OS notification, tap, navigation, and foreground banner. Two defects fixed to get there. |
| Fix M4 (competing M-Pesa surfaces) | ✅ **Closed** — one authoritative payout surface, verified on device against live production state. |
| Establish the Android 5.1 boundary | ✅ **Established** — install refused, root cause identified, boundary is doubly enforced. |
| *(unplanned)* **C2 — `/dev/*` open to the internet in production** | ✅ **Found and fixed**, deployed as `2416e32` |

---

## Verdict first

**Help24 is technically ready for controlled beta testing on the current Android release.**

All blocking findings across rounds 1–3 are **fixed and verified in production and on the physical device**: C1 and H1 (round 2), and **C2, M4, N1 and L4** (round 3).

Round 3 produced **one new critical finding** — `/dev/*` was reachable unauthenticated in production, including routes that wipe transactions and inject `payment.success` events. It was found while proving push delivery, fixed, deployed, and re-probed. Round 2's statement that "no new critical or high finding was produced" was true of what round 2 looked at; it was not true of the system.

The remaining items are log hygiene, two known product-consistency gaps, and unmeasured Android 7–11 behaviour — none of them block a supervised beta.

The architecture freeze held throughout: every fix was small, driven by measured production evidence, and added no new infrastructure. The one new backend file is a regression spec.

---

## FIXED

### C1 — Payout-destination routes accepted unauthenticated callers asserting any `user_id` ✅ FIXED

**What was wrong (round 1):** production runs `AUTH_ENFORCEMENT=enforce` narrowed to `enforceOnly=[/PROMOTIONS]`, so every other `@Auth` route ran in monitor behaviour. An unauthenticated `curl` to `/payout-destinations` naming another person's uid reached the controller and was stopped only by the feature flag (`userIdSource:"asserted"`, `authWouldDeny:"absent"`).

**The fix — `@AuthCritical`** (`backend/src/common/auth/auth.decorator.ts`). Identical semantics to `@Auth` under enforcement, but `critical: true` in the route's `AuthSpec` makes `AuthGuard` enforce **regardless of `AUTH_ENFORCEMENT` / `AUTH_ENFORCE_ONLY`**. All six payout routes now carry it. The migration staging for every other route is untouched — deliberately, so the graduated rollout keeps working everywhere else.

The reasoning recorded at the decorator: *a route that decides where money goes must never be one env-var edit away from monitor behaviour.* This moves the decision from configuration into the route declaration, where code review sees it.

**Production proof (deploy `5e5ea28`, live):**

| Probe | Result |
|---|---|
| Anonymous `GET` asserting a real uid | **401** `AUTH_REQUIRED` — "Sign in to continue." |
| Anonymous `POST` asserting a **foreign** uid + real msisdn | **401** `AUTH_REQUIRED` |
| Garbage bearer token | **401** `TOKEN_INVALID` — "Your session is no longer valid." |
| Anonymous `POST …/retire` (state-changing) | **401** |
| **Authenticated app request** (real device, signed-in user) | **reaches the route**, log shows `userIdSource:"verified"`, `authEnforced:true`, `authScheme:"firebase"`, then `503` from the flag |

That last line is the whole fix in one log entry: `authEnforced:true` on `/payout-destinations` **while `AUTH_ENFORCE_ONLY` is still `/promotions`**, and the uid taken from the verified token rather than the query string.

**No collateral damage** (same production run): `/feed`, `/config`, `/promotions/packages`, `/reputation`, `/health`, `/mpesa/health` all still **200**; `/promotions/campaigns` still **401** (existing enforcement unweakened); `/jobs/:id/status` still **200** (an ordinary `@Auth` route outside the allowlist keeps monitor behaviour — the migration is genuinely untouched).

**Regression tests:** 16 cases in `backend/src/common/auth/auth.critical.spec.ts`, run against the exact production config that let C1 through — anonymous → 401, anonymous asserting a foreign uid → 401, anonymous in *monitor* mode → 401, own uid bound, foreign uid → **403 in both enforce and monitor**, `unavailable` → 503 (never signs users out), public routes still open, ordinary `@Auth` routes still in monitor. Plus a sweep over the real controller metadata that fails if any payout handler loses the decorator or a new one is added without it.

**Boot audit after the change:** `117 routes — firebase=45 admin=49 public=23 undeclared=0 (mode=enforce)`.

**The launch-sequence rule still stands:** `PAYOUT_DESTINATIONS_ENABLED=true` must never be set before `PAYOUT_OTP_PEPPER` is set. C1 no longer gates it — auth is now unconditional on those routes — but the pepper does.

### H1 — The app believed notifications were enabled while the OS had them blocked ✅ FIXED

**What was wrong (round 1):** on the A21s (Android 12), `dumpsys notification` showed `allowNoti=false` while the app registered an FCM token and reported success, because `_requestPermission()` trusted `FirebaseMessaging.authorizationStatus` — which reflects the Android 13+ *runtime permission*, not the user's notification toggle, and is `authorized` on Android 12 regardless.

**The fix.** `mobile-app/lib/services/notification_capability.dart` is a pure decision function — **the OS answer outranks Firebase** — consumed by `NotificationService` via a real `areNotificationsEnabled()` probe (`AndroidFlutterLocalNotificationsPlugin`), plus a `capability()` method safe to call from build paths and a settings deep-link. The Preferences toggle now shows the blocked state and offers the fix.

One deliberate behaviour: an **OS-level block still keeps the FCM token registered**, so delivery resumes the instant the user re-enables notifications — no app round-trip required. Only a hard `denied` skips registration.

**Device proof — the full state machine on the S20+ (Android 13):**

| State | OS truth (`dumpsys`) | App detection (logcat) |
|---|---|---|
| Baseline enabled | `importance=DEFAULT`, appop `allow`, `granted=true` | `fcm=authorized osEnabled=true → enabled` ✅ |
| **Blocked** (user tapped "Don't allow" on the real Android 13 prompt) | `importance=NONE`, appop `ignore`, `granted=false USER_FIXED` | `fcm=denied osEnabled=false → **osBlocked**` ✅ |
| Re-enabled (Settings toggle) | `importance=DEFAULT`, appop `allow`, `granted=true` | `fcm=authorized osEnabled=true → enabled` ✅ |

**Android 13 runtime permission verified end to end:** the `POST_NOTIFICATIONS` prompt ("Allow Help24 to send you notifications?") was captured on screen, awaiting input, with the feed rendered behind it — the path that could not be exercised on the SDK 31 device in round 1. Denying it produced the correct `osBlocked` detection.

**UI proof:** with notifications OS-blocked, the Preferences tile read **"Notifications — Blocked in phone settings — tap to fix"** with the switch off (screenshot captured). After re-enabling, the subtitle correctly disappeared.

**Android 12 behaviour preserved:** the pure-function tests cover the exact round-1 case — `fcmAuthorized: true, osEnabled: false → osBlocked` — which is the Android 12 signature, since below 13 FCM reports `authorized` regardless. 6 cases in `mobile-app/test/notification_capability_test.dart`, all passing.

**FCM token registration still works:** 9 tokens registered for the test account in `users.fcm_tokens`, and re-registration was observed after the permission was restored.

### C2 — the `/dev/*` test harness was open to the internet in production ✅ FIXED (round 3)

**This was not on the task list. It was found while trying to originate a real push, and it is the most serious finding of any round.**

The entire `DevController` was reachable **unauthenticated on the production deploy**:

| Route | What it does |
|---|---|
| `POST /dev/reset-state` | **Wipes transactions, escrow and events** for any `post_id` |
| `POST /dev/trigger-event` | **Injects and immediately processes any canonical event** — including `payment.success`, which drives escrow release |
| `POST /dev/test-fcm` | Sends an arbitrary push to any user's registered devices |

**Production evidence (deploy `5e5ea28`, before the fix):**

```
[AUTH][WOULD_DENY] POST /dev/test-fcm — reason=absent mode=enforce
                   enforcing=false asserted=none ua="curl/8.21.0"
POST /dev/test-fcm 200   authScheme:"firebase"  authWouldDeny:"absent"
requestId 1f81cc3d-4e2b-441f-a9cb-274fe214e5bd
```

An anonymous `curl` reached the controller and executed it. **200, no credential.**

**Why both guards were off — and this is the instructive part:**

1. **`@Auth()` ran in monitor behaviour.** Production runs `AUTH_ENFORCEMENT=enforce` narrowed to `enforceOnly=[/PROMOTIONS]`. C1 taught this lesson for payout routes and fixed it *there*; nobody asked which *other* routes were dangerous. `/dev/*` is strictly more dangerous than `/payout-destinations` — it destroys state rather than reading it.
2. **`guardDev()` keyed on the wrong variable.** It read `MPESA_ENV !== 'production'`, tying "is this a test harness?" to "which Daraja environment do we bill against?" — two unrelated questions. Production runs `MPESA_ENV=sandbox` because the Daraja cutover has not happened, so the guard **passed**. The source comment claimed "all calls are no-ops in production." That comment was false, and had been false for as long as the harness existed.

Two independent controls, both defeated by the same root cause: **a safety check that depends on configuration meant for something else.**

**The fix (commit `2416e32`, deploy `dep-d9re7q37uimc73avrro0`):**

- `DevController` now carries **`@AuthCritical()`** — enforced regardless of `AUTH_ENFORCEMENT`/`AUTH_ENFORCE_ONLY`, exactly like the payout routes.
- `guardDev()` now requires an explicit, **default-closed `DEV_ROUTES_ENABLED === 'true'`**. Unset means off, so no deployment can inherit the harness by accident, and it is no longer coupled to any payments setting.

**Production proof after deploy:**

| Probe | Result |
|---|---|
| Anonymous `POST /dev/test-fcm` | **401** `AUTH_REQUIRED` — "Sign in to continue." |
| Anonymous `POST /dev/reset-state` | **401** |
| Anonymous `POST /dev/trigger-event` | **401** |
| Garbage bearer token | **401** `TOKEN_INVALID` — "Your session is no longer valid." |

**No collateral damage** (same run): `/health`, `/config`, `/feed`, `/promotions/packages`, `/mpesa/health` all still **200**; `/promotions/campaigns` still **401**; `/payout-destinations` still **401**. The graduated auth migration is untouched everywhere else.

**Regression tests:** 10 cases in `backend/src/dev/dev.harness-guard.spec.ts` pinning **both** layers — `MPESA_ENV=sandbox` no longer opens the harness, unset means closed, only the exact string `"true"` opens it, every entry point is guarded, and a metadata assertion that fails if the controller ever loses `critical: true`.

**Residual risk to note:** C1 and C2 were the same class of defect found twice. Every other `@Auth` route in the system is still in monitor behaviour. That is deliberate (the migration), but the selection of which routes get `@AuthCritical` has so far been reactive. A route-by-route review of what else is destructive is worth doing before public launch — it is not a blocker for a supervised beta, where the traffic is known.

---

## Push Delivery

**Status: PROVEN end to end.** This was the round-2 gap ("do not treat H1's fix as proof that pushes arrive"). It is now closed with a real notification on real hardware.

### How it was originated

The Firebase service-account credential lives only in Render's environment and was **never copied locally**. The push was originated by the existing production `POST /dev/test-fcm` endpoint, which calls Firebase Admin **inside Render** — i.e. the existing production infrastructure sent the message, exactly as instructed. No new notification architecture was introduced. (That endpoint's auth posture is C2 above; it now requires a signed-in caller.)

### The chain, with evidence at every hop

| Hop | Evidence |
|---|---|
| **Token registration** | `[FCM][TOKEN_SAVE] upsert token for uid=nlAJ… platform=android` → `[FCM][TOKEN_SAVE] done` |
| **Token persisted** | `public.fcm_tokens` row for the uid, `platform=android`, `len=142`, `updated_at=2026-08-08 07:40:41Z` (queried directly) |
| **Originating request** | `POST /dev/test-fcm {"userId":"nlAJ…"}` |
| **Render log** | `[DEV] POST /dev/test-fcm — userId=nlAJ…`, `POST /dev/test-fcm 200`, requestId `f5e62e7b` |
| **FCM acceptance** | `{"ok":true,"tokensSource":"fcm_tokens_table","successCount":1,"failureCount":0,"results":[{"success":true}]}` |
| **Notification on device** | `dumpsys notification`: `pkg=com.help24.help24 … channel=help24_high_importance importance=4`, `android.title="🔔 TEST PUSH"`, `android.text="If you see this, FCM is working end-to-end."` |
| **Visible on screen** | Screenshot of the notification shade showing the card with the Help24 icon, 10:41 AM |
| **Background isolate** | `[FCM][REMOTE_RECEIVED] bg id=0:1786174875135858%…` → `[FCM][BACKGROUND_HANDLER] type=test` |
| **Tap** | `[FCM][OPENED] data={type: test, userId: nlAJ…}` |
| **Navigation** | `[NAV][NOTIFICATION_OPEN] type=test` → `[NAV][ROUTE_RESOLVED]` → NotificationsScreen; app came to foreground, screenshot shows the real notification history |

**Foreground behaviour** (separate path, separately proven): `[FCM][REMOTE_RECEIVED] fg …` → `[FCM][AUTO_NOTIFICATION_BLOCKED] foreground=true — OS notification suppressed; in-app banner only` → screenshot of the in-app banner rendered over the Discover feed. Exactly one card in each mode — no duplicate.

**Re-proven after a full logout → login cycle**, so this is not a one-off: token removed on logout, re-saved on login, and a subsequent push delivered `successCount:1` with the OS card posted on the correct channel.

### Two real defects found by doing this

Neither would have been found by reading code, and both were invisible to the round-2 conclusion.

**N1 — every foreground push showed the user nothing.** The in-app banner threw on **every** foreground message:

```
Unhandled Exception: Null check operator used on a null value
  #0  Overlay.of (package:flutter/src/widgets/overlay.dart:616)
  #1  NotificationBannerOverlay.show (notification_banner.dart:30)
  #2  _Help24AppState._onForegroundMessage (main.dart:307)
```

`main.dart` passed `_navigatorKey.currentContext` — the context **of** the `Navigator` widget. That navigator's `Overlay` is its *descendant*, so an ancestor lookup finds nothing and `Overlay.of`'s `!` throws. Because the OS card is *deliberately* suppressed in the foreground, the user got **no card and no banner** — silence. **Fixed:** the navigator's own `OverlayState` is passed in, and `show` now uses `Overlay.maybeOf` so a missing overlay degrades to "no banner" instead of an unhandled exception. Verified on device: banner renders, zero unhandled exceptions in the session.

**N2 — the round-2 "9 tokens registered" figure was misleading.** All 9 were **dead**: `messaging/registration-token-not-registered` on every one, `successCount:0 failureCount:9`. The device's live token was not in the database at all.

Root cause was **not** a bug: `users.notifications_enabled` was `false` in the database, left over from the H1 test round. H1's re-enable was done through **Android Settings**, which correctly restores the OS permission but does not touch the app-level preference — so `addFcmToken` was skipped by design and no token was saved. Enabling the toggle in the app's own Preferences UI immediately produced `[FCM][TOKEN_SAVE] done` and a live row.

This matters as a **product** observation rather than a defect: a user who turns Help24 notifications off in-app and later re-enables them *in Android settings* will believe notifications are on — the OS agrees, the app's H1 detection agrees — while the backend holds no token for them and can never reach them. Worth reconciling before relying on push for retention.

**L4 fixed as a consequence.** Stale-token pruning existed but only ever deleted from the `fcm_tokens` **table**. Tokens read from the legacy `users.fcm_tokens` JSONB fallback were "pruned" from a table they were not in — a silent no-op, which is precisely how 9 dead tokens accumulated on one account. Pruning now follows whichever source it read from, and re-reads before rewriting so a token registered mid-send is not dropped.

---

## Payment Surface Consolidation (M4) ✅ CLOSED

### What the legacy surface was actually for

Traced through the whole Flutter navigation and state flow, and through the backend that consumes the value. `users.phone_number` has **three** distinct consumers, and only one of them is payouts:

| Consumer | Where | Payout-related? |
|---|---|---|
| **Buyer STK push** — the number the client is *charged* | `mpesa.service.ts:171-182` | **No.** Legitimate and permanent. |
| **Provider contact / hireability** (`ProviderReadiness`) | `provider_gate.dart:67` | **No.** Legitimate and permanent. |
| **Provider B2C payout — but only while the flag is off** | `mpesa.service.ts:603-615` | **Yes, today.** |

That third row is the finding that reframes M4. **With `PAYOUT_DESTINATIONS_ENABLED` off — which is production right now — the backend genuinely settles B2C payouts to `users.phone_number`.** So the legacy copy *"This number is used for M-Pesa payments and payouts"* was **accurate**, and becomes a dangerous lie the moment the flag flips. Deleting the surface, or hard-coding "this number does not control payouts", would have been a lie in the *opposite* direction — one that could make a provider believe they are unpayable when they are not.

### What was done

The surface has a legitimate non-payout purpose, so per the brief it was **renamed and restructured**, not deleted.

- **"Payment Settings" → "Payment Number"**, subtitled *"254••••••999 · the number you pay from"*. Unambiguous against **"Payout Destinations — Where your M-Pesa earnings are sent"**: money *out of* your pocket vs money *into* it.
- **The payout claim is never hard-coded.** `mobile-app/lib/services/payout_authority.dart` is a pure decision function (same idiom as `notification_capability.dart`) resolving from the same production signal the rest of the app already uses — `/payout-destinations` answers **503** while the flag is off:

| Resolved state | What the sheet says |
|---|---|
| `destinations` (feature live) | "Payouts are **NOT** sent here…" + a button straight to Payout Destinations |
| `profileNumber` (flag off) | "Payouts currently go to this number too. Verified payout destinations are being rolled out — once available, they take over." |
| `unknown` (offline / 401 / 5xx) | **Nothing at all** — silence, per the state-truthfulness contract |

Only a clean 200 proves the feature is live; only the documented 503 proves it is off. A 401, 429 or 500 resolves to `unknown` and the sheet stays silent rather than guessing.

### Device verification against live production state

Screenshot evidence on the S20+ with the flag genuinely off: the Payment Number sheet renders *"Payouts currently go to this number too…"* — which is **true**, resolved live from a real 503 (`GET /payout-destinations 503`, `userIdSource:"verified"`, `authEnforced:true`, requestId `dd2b9ced`). Both Business tiles and the Account tile were visible on one screen with no ambiguity between them.

### Every copy site swept

Searched the entire Flutter project for `Payment Settings`, `payment settings`, `M-Pesa`, `payout`, `phone number` and the old routes. Beyond the two obvious screens, the sweep caught payout claims that were **not** in the visible sheet:

| Site | Was | Now |
|---|---|---|
| `provider_gate.dart:41` | *"This is how you get paid when a client selects you."* | *"Clients need a way to reach you before they can select you."* |
| `profile_completion.dart:198` | *"Verified in Account · needed to get paid"* | *"Verified in Account · how clients reach you"* |
| `professional_profile_screen.dart:247` | *"Add it in Account to get paid"* | *"Add it in Account so clients can reach you"* |
| `professional_profile_screen.dart:140` | *"used for M-Pesa payments and payouts"* | scoped to pay-from + contact, points at Payout Destinations |
| `provider_onboarding_screen.dart:237` | *"Added under Account → Payment Settings"* | renamed + *"not where payouts are sent"* |
| `payment_screen`, `job_status_card`, `post_detail_screen` | *"…Profile → Payment Settings."* | *"…Profile → Payment Number."* (buyer-side, legitimately about paying) |

### The invariant, verified

> There is exactly ONE authoritative UI for configuring where provider payouts are sent: **Payout Destinations**.

| Requirement | Status |
|---|---|
| Adding a destination uses the new flow | ✅ `PayoutService.addDestination` has exactly one call site — asserted by test |
| OTP verification uses the new flow | ✅ `payout_otp_screen.dart` only |
| Setting default / retiring use the new flow | ✅ `payout_destinations_screen.dart` only |
| Provider onboarding points to the new flow | ✅ step 3 routes to `PayoutDestinationsScreen` |
| No legacy UI implies its number controls payouts | ✅ swept; guarded by test |
| No stale "used for payments and payouts" copy | ✅ removed; guarded by test |
| No two competing payout editors | ✅ asserted by a test that enumerates `lib/` and fails on a second editor |

**Honest caveat:** the invariant is *unconditionally* true once `PAYOUT_DESTINATIONS_ENABLED=true`. Until then, the profile number still receives payouts — that is backend behaviour, not UI. The app now **states which one governs** instead of implying both, which is the strongest truthful position available while the flag is off.

**Regression tests:** 12 cases in `mobile-app/test/payout_authority_test.dart` — the decision function, the note text, and a **copy guard** that fails the build if `"payments and payouts"` or the name `"Payment Settings"` returns to any profile-number surface, or if a second payout editor appears.

---

## Android 5.1 Compatibility

### The declared boundary, proven from artefacts

| Property | Value | Source |
|---|---|---|
| **minSdk** | **24** (Android 7.0) | `aapt dump badging` → `sdkVersion:'24'` |
| targetSdk | 36 | APK badging |
| compileSdk | 36 | `android/app/build.gradle:29` |
| Gradle declaration | `minSdkVersion flutter.minSdkVersion` | `build.gradle:48` — inherits Flutter's default, which resolves to 24 |
| On-device confirmation | `minSdk=24 targetSdk=36` | `dumpsys package com.help24.help24` (S20+) |
| ABIs | arm64-v8a, armeabi-v7a, x86_64 | APK badging |

**minSdk was NOT changed.** It remains 24.

### The install attempt — exact result

Device: **OPPO X9009**, `ro.build.version.release=5.1`, `ro.build.version.sdk=22`, arm64-v8a.

```
$ adb -s 4PUGSC4PHUEYVC6T install -r app-release.apk
  app-release.apk: 1 file pushed ... (72136315 bytes in 12.176s)
  Performing Push Install
  pkg: /data/local/tmp/app-release.apk
  Failure [-99]
```

`-99` is not a named code, so the package manager was asked directly:

```
$ adb shell pm install -r /data/local/tmp/app-release.apk
  Failure [INSTALL_FAILED_INVALID_URI]

logcat:
  W/DefContainer: Failed to parse package at /data/local/tmp/app-release.apk:
    android.content.pm.PackageParser$PackageParserException: Failed to parse …
```

**Result: installation REJECTED.** ✅ Expected, and the boundary is confirmed.

### Why it failed — and it is not the error we predicted

The interesting part: it did **not** fail with `INSTALL_FAILED_OLDER_SDK`. It failed **earlier**, at parse time. Root cause:

```
$ apksigner verify --verbose app-release.apk
  Verified using v1 scheme (JAR signing): false
  Verified using v2 scheme (APK Signature Scheme v2): true
```

The APK is **v2-signed only, with no v1/JAR signature**. APK Signature Scheme v2 was introduced in **Android 7.0 (API 24)**. Android 5.1 cannot verify a v2 signature, falls back to v1, finds none, and `PackageParser` fails before the SDK check ever runs.

This is not a defect — it is AGP behaving correctly. When `minSdk >= 24`, AGP omits v1 signing because no supported device needs it. **The boundary is therefore enforced twice over, independently:** by the declared `minSdk 24`, and by the signature scheme itself. A device below API 24 cannot install this APK even if the manifest gate were removed.

### Does a debug build behave differently? No.

Built and tested to answer the question rather than assume it:

```
app-debug.apk (175.7 MB)
  Verified using v1 scheme (JAR signing): false
  Verified using v2 scheme (APK Signature Scheme v2): true
$ adb -s 4PUGSC4PHUEYVC6T install -r app-debug.apk
  Failure [-99]
```

**Identical.** The rejection is a property of the build configuration, not of release signing.

### Play Store filtering

Play excludes API < 24 automatically from `uses-sdk:minSdkVersion="24"`. An Android 5.1 user would never be offered the app; this device would not see it in the Play listing at all. The ADB result above is what happens when the store gate is bypassed by sideloading.

**No attempt was made to bypass the minimum SDK, and `minSdk` was not lowered.**

---

## Android compatibility

### What the release actually declares

Measured from the built APK with `aapt dump badging` — not from source:

```
package: com.help24.help24  versionCode=1  versionName=1.0.0
sdkVersion:'24'          ← minSdk
targetSdkVersion:'36'
compileSdkVersion='36'
native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'
```

Confirmed independently on-device: `dumpsys package com.help24.help24` → `minSdk=24 targetSdk=36`.

| Property | Value | Source |
|---|---|---|
| **minSdk** | **24 → Android 7.0 Nougat** | APK badging + on-device dumpsys |
| targetSdk | 36 | APK badging |
| compileSdk | 36 | `android/app/build.gradle:29` |
| ABIs | arm64-v8a, armeabi-v7a, x86_64 | APK badging |
| APK size | 68.8 MB (universal, all ABIs) | build output |
| Flutter | 3.44.4 stable | `flutter --version` |

`minSdkVersion flutter.minSdkVersion` (`build.gradle:48`) — the project inherits Flutter's default rather than pinning one, and that default resolves to **24** in this Flutter version.

### Do the dependencies actually permit 24?

**Yes, and the build proves it.** AGP fails a build with `uses-sdk:minSdkVersion X cannot be smaller than version Y declared in library` whenever any dependency declares a higher floor. This release **builds and installs at minSdk 24**, so no plugin in the tree — `firebase_messaging`, `flutter_local_notifications`, `permission_handler`, `local_auth`, `google_maps_flutter`, `geolocator`, `image_picker`, `cloud_firestore`, `connectivity_plus`, `file_picker` — declares a floor above 24. The merged manifest report confirms every plugin merged into the app's injected `uses-sdk` without an override. Firebase BoM 34.12.0 requires API 23; 24 satisfies it.

### Would Android 7 / 8 / 9 realistically *work*?

**Honest answer: unproven, with one specific identified risk.** I had no Android 7/8/9 hardware in this session and did not substitute an emulator, so this is **not measured**.

The concrete risk is **TLS trust anchors**, not Flutter support. Every backend the app depends on now serves certificates from **Google Trust Services**:

| Host | Issuer | Chain root sent |
|---|---|---|
| `help24-backend.onrender.com` | GTS **WE1** | GTS Root R4 |
| `taohzhnvaitrpxcyjflq.supabase.co` | GTS **WE1** | GTS Root R4 |
| `firebaseinstallations.googleapis.com` | GTS **WE2** | (GTS) |

GTS roots were added to the Android system trust store in later releases than 7.0; devices older than that historically validated Google-issued certificates through a cross-signed path. Whether a **specific unpatched Android 7.x handset** still builds a valid path to `GTS Root R4` today is exactly the kind of claim that must be tested, not reasoned about — a failure here is total (every API call fails TLS), not partial.

**Recommendation:** either test one real Android 7.x device before advertising 7.0 support, or raise `minSdk` to 26 (Android 8.0) and let Play filter the rest. Do **not** change it on the strength of this paragraph alone — that decision needs its own evidence, and this audit was scoped to the current release.

### Play Store device filtering

Play will offer this build to **Android 7.0 (API 24) and above** on arm64-v8a, armeabi-v7a and x86_64 — i.e. effectively every Android phone in the Kenyan market. Devices below API 24 are excluded automatically. The 68.8 MB universal APK is the size every device downloads; an app bundle with per-ABI splits would cut roughly half of that, which matters on metered mobile data (not a launch blocker — a cost item).

---

## The Android support boundary — the three things that are not the same

These get conflated constantly, so they are stated separately.

### 1. Declared support

**`minSdk` = 24 → Android 7.0 Nougat.** Measured from the built APK (`aapt dump badging`) and confirmed on-device (`dumpsys package`). Unchanged this round.

### 2. Installable range

**API 24 (Android 7.0) and above**, on arm64-v8a / armeabi-v7a / x86_64.

Enforced twice, independently: the manifest `uses-sdk`, and the fact that the APK carries **only a v2 signature**, which no device below API 24 can verify.

### 3. Actually tested on physical hardware

| Android | API | Device | Result |
|---|---|---|---|
| **5.1** | **22** | OPPO X9009 | ❌ **Install rejected** — `INSTALL_FAILED_INVALID_URI`, parse failure (v2-only signature). Expected. |
| 7.0–11 | 24–30 | — | **Never tested.** No hardware in any session. |
| **12** | **31** | Galaxy A21s | ✅ Verified (rounds 1–2) |
| **13** | **33** | Galaxy S20+ | ✅ Verified (rounds 2–3), primary device |

### The statement, as required

> **The application declares API 24 as its minimum SDK, therefore Android 5.1 / API 22 is outside the supported installation range. Android 7.0 / API 24 is the declared floor. Physical compatibility below that floor is not supported.**

**Does the API 22 test confirm that boundary? Yes.** The install was refused on real Android 5.1 hardware, and the refusal is stronger than the manifest gate alone — the signature scheme makes it structural.

**What the test does NOT confirm**, and this must not be blurred: it says nothing about **API 24–30**. "Declared floor 24" is not "verified working on 24". The oldest version *verified working* is **Android 12 (API 31)**. The unresolved **TLS trust-anchor question on Android 7.x** (§Android compatibility above) remains untested and would break every network call if it bites. Do not advertise "Android 7+" as verified.

---

## PASSED — verified on the S20+ in round 2

*(Round 3's re-run is a separate section below. Everything here still held when re-tested.)*

**Launch & session**
- **Cold start 393 ms**, **hot start 71 ms** (`am start -W`, activity launch time).
- Session restored silently from the previous install — no re-login (`uid=nlAJnbHFktNTYEGPPPrBE1zu0RB2`, alphlincoln18@gmail.com).
- Token refresh observed working: `[AUTH][BRIDGE] 401 → token refreshed, replaying request`.
- Supabase RLS bridge active: `[AUTH][BRIDGE] ok=true — authenticated JWT active for RLS`.

**Remote config**
- `GET /config` → 200, `etag: W/"3b6c0888a44bf4c1"`, `Cache-Control: public, max-age=60`; conditional `If-None-Match` → **304**. Kill switches, maintenance, min_version, announcement all present and inactive as configured.

**Feed**
- Real production content rendered: ranked posts, images, avatars, reputation, locations, "New Provider" badges, relative timestamps, price ("From KES 500"), category chips.
- Filter chips (All / Requests / Offers), search field, and per-type CTAs ("Enquire" vs "Offer Service") all present and correct.

**Profile**
- Loaded with live data: name, email, confirmed profession (Electrician), 3.5★ / 2 reviews, 6 jobs completed, 67% completion, 44% dispute rate, 13 active posts, 75% profile completion with next-step hint.

**Provider & payouts (the new work)**
- Both new entry points live in Business: **"Become a Provider — Profession, contact & verified payout number"** and **"Payout Destinations — Where your M-Pesa earnings are sent"**.
- **Flag-off behaviour exactly as specified**: *"Not available yet — Payout number verification is being rolled out. Check back soon — your earnings are unaffected."* No crash, no raw error, no stack trace, no dead end.
- Backend correlation: `route:/payout-destinations`, `rateLimitPolicy:payout:read`, `authScheme:firebase`, `userIdSource:verified`, `authEnforced:true`, latency 2.0–2.6 ms.

**Notifications** — see H1 above for the full three-state proof, the Android 13 runtime prompt, and token registration.

**Offline & recovery**
- Airplane mode: "No internet connection" banner appears and the **cached feed stays on screen** — the frozen-snapshot contract held on Android 13 too, no wipe to empty.
- Failures during the offline window degraded gracefully and said so: `[PROMO] fetchSlots failed (feed stays organic)`.
- Reconnect: realtime resubscribed automatically; no stuck state.

**Stability**
- **Zero crashes, zero ANRs** (`dumpsys activity` → *"no ANR has occurred since boot"*), zero unhandled Flutter errors. The only `I/flutter` error lines in the session were the expected host-lookup failures during airplane mode, each handled.
- Memory after ~25 minutes of navigation including permission cycling: **247.9 MB TOTAL PSS**, 51.6 MB native heap, 3.9 MB Dalvik heap. Higher than the A21s figure (149.9 MB) as expected on a 1440p device; no leak signature.

**Backend health during testing**
- Since deploy `5e5ea28`: **zero unexpected errors**. The only error-level lines are the four produced by my own intentional payout probes (`503`, flag off).
- **Zero 5xx**, zero queue failures, zero worker failures. Event processor alive, `queueSize=0`; promotions sweep running; dead letters steady at 1 (the known June artifact).
- Route audit on the live deploy: `117 routes — undeclared=0`.

---

## Could NOT be measured (stated rather than inferred)

- ~~**Notification delivery**~~ — **RESOLVED IN ROUND 3.** See §Push Delivery: delivery, tap, navigation and foreground banner are all now proven on the S20+. The round-2 claim that "9 tokens persisted" was also **wrong in substance** — all 9 were dead; see N2.
- **Frame-level jank** — `dumpsys gfxinfo` reports 0 frames for this app (Flutter renders outside the Android View pipeline gfxinfo instruments), and `SurfaceFlinger --latency` did not expose the Flutter layer on this Samsung build. Scrolling was subjectively smooth with no ANR, but there is **no measured jank percentage** and I will not invent one. A `--profile` build with DevTools is required for a real number.
- **Android 7/8/9 behaviour** — no such hardware in this session; see the TLS caveat above.
- **Payout write paths** (add destination → OTP → verify → default → retire) — unreachable while the flag is off, by design. Covered by backend tests only.

---

## Final Remaining Issues (evidence-backed only)

### Closed this round

- **C2 — `/dev/*` open in production** ✅ fixed and verified (deploy `2416e32`).
- **M4 — two competing M-Pesa surfaces** ✅ closed and verified on device.
- **N1 — foreground push showed nothing** ✅ fixed and verified on device.
- **L4 — dead FCM tokens never pruned** ✅ fixed (legacy-JSONB pruning path added).

### MEDIUM

- **M1 — Expected feature-flag 503s are logged at ERROR level.** Confirmed a third time: the four `ERROR` lines in this round's Render logs are *all* flag-off 503s from `/payout-destinations`, two of them produced by the new Payment Number sheet's authority probe. The error log is how this project judges production health; the M4 fix now generates this noise on a normal screen open, which makes M1 slightly worse than it was. Log expected feature-gate responses at `warn`.
- **M5 — Provider gate and onboarding hub don't know about each other.** The gate copy is corrected and no longer claims the contact number pays you, but "Offer Service" still shows the older sheet without mentioning "Become a Provider" or payout verification. Two entry points, different stories. (Item P1 in `provider-experience-sprint.md`.)
- **M2 / M3 — Duplicate cold-start `/feed` requests and N+1 reputation fetches.** Measured in round 1 on the A21s; not re-measured since. Carried forward unchanged.
- **M6 (new) — Re-enabling notifications in Android settings does not restore delivery.** Turning Help24 notifications off *in-app* sets `users.notifications_enabled=false` and removes the token. Re-enabling them in **Android Settings** restores the OS permission — and the app's H1 detection correctly reports "enabled" — but never flips the app-level flag, so no token is registered and the backend can never reach that user. The user, the OS and the app all believe notifications work. Discovered as the root cause of N2. Not a blocker for a supervised beta, but it silently disables push for anyone who takes that path.

### LOW

- **L2 — Jank not instrumentable** (see above). Unchanged; still needs a `--profile` build with DevTools for a real number.
- **L3 — Backend validation messages are developer-shaped.** They never reach users (ErrorMapper's clean-message filter rejects them), but would be unhelpful if surfaced.
- **L5 (new) — `/dev/*` routes ship in the production bundle at all.** They are now default-closed and auth-critical, which is sufficient. Excluding the module from production builds entirely would remove the class of risk rather than guard it. Worth considering, not urgent.
- **L6 (new) — the `@AuthCritical` selection is reactive.** C1 and C2 were the same defect found twice, each time only after a probe hit it. Every other `@Auth` route remains in monitor behaviour by design. A deliberate pass over which routes are destructive — rather than waiting for the next probe — is worth doing before public launch.

### Withdrawn

**B1 in `launch-readiness-sprint.md` remains withdrawn.** `api_config.dart:22` defaults to the production origin; a no-flag release APK talked to production throughout both device sessions.

---

## Round 3 regression run — S20+ (build `2416e32`)

Re-run after the fixes, with Render logs watched throughout.

| Area | Result |
|---|---|
| Cold start | ✅ 437 ms / 950 ms (post-install first run); `LaunchState: COLD` |
| Session restoration | ✅ silent restore, `uid=nlAJ…`, RLS bridge `ok=true`, `401 → token refreshed, replaying request` |
| Feed | ✅ real ranked production content, images, badges, prices, per-type CTAs |
| Search | ✅ `"plumb"` → correctly filtered Plumbing results, "Showing all posts for…" |
| Provider onboarding | ✅ 3-step hub renders; payout step reports the flag-off state |
| Payout Destinations | ✅ *"Not available yet — …your earnings are unaffected."* No crash, no dead end |
| Disabled payout state | ✅ `GET /payout-destinations 503`, `userIdSource:"verified"`, `authEnforced:true` (C1 still holding) |
| **Payment Number (M4)** | ✅ renamed, scoped, truthful authority note resolved from the live 503 |
| Notification permission state | ✅ `fcm=authorized osEnabled=true → enabled` |
| **Real notification delivery** | ✅ `successCount:1`, OS card on `help24_high_importance` |
| **Notification tap navigation** | ✅ `[FCM][OPENED]` → `[NAV][ROUTE_RESOLVED]` → correct destination |
| **Foreground banner** | ✅ renders (was throwing before N1 fix) |
| Offline / reconnect | ✅ cached feed retained (frozen-snapshot contract held), realtime auto-resubscribed on restore |
| Logout | ✅ token removed, `[SESSION] purged 5 user-scoped key(s)`, correct signed-out UI |
| Login | ✅ Google sign-in, same uid, `[FCM][LOGIN] token saved`, push re-verified after |
| Stability | ✅ **zero ANRs** (`<no ANR has occurred since boot>`), **zero unhandled Flutter exceptions**, 261 MB TOTAL PSS |
| Render logs | ✅ **zero 5xx, zero unexpected errors.** The only ERROR lines are the four expected flag-off 503s (M1) |

---

## Final Controlled-Beta Verdict

### 1. Is Help24 ready for controlled beta?

**Yes — and materially more so than at the end of round 2, because round 2's verdict rested on an unproven assumption and one undetected critical exposure.**

Everything round 2 verified still holds, plus: push delivery is proven rather than assumed, the payout surface is unambiguous, and a route that could wipe transactions and inject `payment.success` events is no longer reachable by anyone on the internet.

Read that last point plainly: **had this beta launched on round 2's verdict, the production backend would have been running with `/dev/reset-state` and `/dev/trigger-event` open and unauthenticated.** That was not caused by the beta; it was already live. It is now closed, verified with real probes against the deployed build.

Conditions, none of which block a supervised beta:
- **M1** should be fixed soon — the M4 work made the error-log noise slightly worse, and error-log cleanliness is this project's health signal.
- **M6** matters if push is load-bearing for retention.
- **L6** — do the deliberate `@AuthCritical` review before *public* launch, not just before beta.

Unchanged launch-sequence rule: **set `PAYOUT_OTP_PEPPER` before `PAYOUT_DESTINATIONS_ENABLED=true`.**

### 2. Is real push delivery proven?

**Yes.** Backend event → Firebase Admin inside Render → FCM → physical Galaxy S20+ → Android notification on `help24_high_importance` (`importance=4`) → tap → correct in-app destination. Captured in `dumpsys notification`, in a screenshot of the notification shade, in device logcat, and in Render logs by `requestId`. The foreground in-app banner path is separately proven. Re-proven after a full logout/login cycle.

**Not** claimed on the strength of FCM accepting a token — that is exactly the mistake round 2 warned about, and it turned out that every token FCM had accepted for this account was dead.

**One honest limit:** the payload carried `type: test`, so tap-routing resolved through the real production router to its correct fallback (NotificationsScreen). Routing to a *specific entity* — e.g. a chat thread from a real `chat_message` push — was not exercised, because originating one requires a second real account. The routing code path is proven; one typed destination is not.

### 3. Is there now exactly one authoritative payout configuration surface?

**Yes — Payout Destinations**, verified by sweep, by device screenshot, and by a test that fails if a second payout editor ever appears.

With the precision the question deserves: *configuring* payouts happens in exactly one place. But while `PAYOUT_DESTINATIONS_ENABLED` is off, the backend still *settles* to the profile number. The app now tells the user which one governs, tracked from the live flag rather than hard-coded, and says nothing when it cannot tell. The invariant becomes unconditional the moment the flag flips — no further UI work required.

### 4. What is the minimum Android version of the current release?

**Android 7.0 Nougat — API 24.** Declared as `minSdk 24` in the APK (`aapt dump badging`), confirmed on-device (`dumpsys package`), unchanged this round.

Enforced twice: by the manifest, and by the APK carrying only a v2 signature (a scheme introduced in API 24), which no earlier device can verify.

*Supported* means "can install". The oldest version **verified working** remains **Android 12 (API 31)**; the primary device is **Android 13 (API 33)**. API 24–30 is still untested, with an open TLS trust-anchor question on Android 7.x.

### 5. What happens on Android 5.1?

**Installation is refused.** On the physical OPPO X9009 (API 22):

- `adb install` → `Failure [-99]`
- `pm install` → `Failure [INSTALL_FAILED_INVALID_URI]`
- logcat → `PackageParser$PackageParserException: Failed to parse`

It fails at **parse time**, before the SDK check — the APK is v2-signed only, and Android 5.1 cannot verify a v2 signature. A debug build behaves identically, so this is a property of the build configuration, not of release signing. Play would never offer the app to such a device.

**This confirms the declared boundary**, and `minSdk` was not lowered or bypassed to make it install.
