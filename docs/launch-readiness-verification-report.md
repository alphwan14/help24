# Launch Readiness Verification Report

**Date:** 2026-08-08 (round 2 — C1/H1 fixes verified)
**Primary device:** Samsung **SM-G986U (Galaxy S20+ 5G)**, **Android 13**, **SDK 33**, **arm64-v8a**, build `TP1A.220624.014`, physical device over ADB (`R5CN218ZKZY`). No emulator.
**Round 1 device:** Samsung SM-A217F (Galaxy A21s), Android 12 / SDK 31 (`R58N624CD2J`) — where C1 and H1 were originally found.
**Build:** `flutter build apk --release` from commit `5e5ea28`, **68.8 MB**, installed via `adb install -r`. No dart-defines — `ApiConfig.baseUrl` resolved to the production default.
**Backend:** `help24-backend` (srv-d7mjm2v7f7vs73f8qaqg), deploy `dep-d9r6etrl550s73ddphug`, commit `5e5ea28`, status **live**.
**Method:** every UI action driven by `adb input`, every screen captured by `adb exec-out screencap`, every backend claim correlated against Render logs by `requestId`, every OS claim taken from `dumpsys`. No claim below is made from code reading alone.

---

## Verdict first

**Help24 is technically ready for controlled beta testing on the current Android release.**

Both blocking findings from round 1 are **fixed and verified in production and on the physical device**. No new critical or high finding was produced by this round. The remaining items are polish, log hygiene, and one product-consistency issue (M4) that matters before providers onboard at volume — none of them block a supervised beta.

The architecture freeze held throughout: both fixes were small, driven by measured production evidence, and added no new infrastructure.

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

## PASSED — verified on the S20+ this round

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

- **Notification delivery** — foreground display, background display, and tap-navigation could **not** be exercised. Sending a real FCM message needs either the Firebase service-account key (held only in Render's environment) or a second account to originate a genuine event; neither was available. What *is* proven: permission state machine, token registration (9 tokens persisted), and channel configuration (`help24_high_importance`, `importance=4`, sound + lights + badge). **Delivery itself remains unverified** — do not treat H1's fix as proof that pushes arrive.
- **Frame-level jank** — `dumpsys gfxinfo` reports 0 frames for this app (Flutter renders outside the Android View pipeline gfxinfo instruments), and `SurfaceFlinger --latency` did not expose the Flutter layer on this Samsung build. Scrolling was subjectively smooth with no ANR, but there is **no measured jank percentage** and I will not invent one. A `--profile` build with DevTools is required for a real number.
- **Android 7/8/9 behaviour** — no such hardware in this session; see the TLS caveat above.
- **Payout write paths** (add destination → OTP → verify → default → retire) — unreachable while the flag is off, by design. Covered by backend tests only.

---

## Remaining issues (evidence-backed only)

### MEDIUM

- **M1 — Expected feature-flag 503s are logged at ERROR level.** Confirmed again this round: one user tap produced two `ERROR` lines (`AllExceptionsFilter` + HTTP logger). The error log is how this project judges production health; a disabled feature a user merely visited should not consume that signal. Log expected feature-gate responses at `warn`.
- **M4 — Two competing M-Pesa number surfaces.** Account → **Payment Settings** (legacy, writes `users.phone_number`, shows `254••••••999`) sits alongside Business → **Payout Destinations** (the verified destinations that actually govern payouts). Both were visible on one screen this round. A provider can set a number in the legacy sheet and reasonably believe they are payable when they are not. **Resolve before providers onboard at volume.**
- **M5 — Provider gate and onboarding hub don't know about each other.** "Offer Service" still shows the older sheet pointing at "Account → Payment Settings", never mentioning "Become a Provider" or payout verification. Two entry points telling different stories. (Item P1 in `provider-experience-sprint.md`.)
- **M2 / M3 — Duplicate cold-start `/feed` requests and N+1 reputation fetches.** Measured in round 1 on the A21s; not re-measured this round. Carried forward unchanged.

### LOW

- **L2 — Jank not instrumentable** (see above).
- **L3 — Backend validation messages are developer-shaped.** They never reach users (ErrorMapper's clean-message filter rejects them), but would be unhelpful if surfaced.
- **L4 (new) — FCM tokens accumulate without pruning.** The test account holds **9** tokens from repeated installs/devices. Sends will fan out to dead tokens, wasting quota and generating `UNREGISTERED` responses. Prune on `UNREGISTERED`, or cap per user. Cosmetic today; grows with every reinstall.

### Withdrawn

**B1 in `launch-readiness-sprint.md` remains withdrawn.** `api_config.dart:22` defaults to the production origin; a no-flag release APK talked to production throughout both device sessions.

---

## Final verdict

### Is Help24 ready for controlled beta testing on the current Android release?

**Yes.** Both round-1 blockers are fixed and verified — C1 in production with real HTTP probes and a real authenticated device request, H1 on a real Android 13 device across all three permission states including the runtime prompt. Zero crashes, zero ANRs, zero unexpected backend errors, zero 5xx. Cold start 393 ms, hot start 71 ms. Offline degradation, session restore, remote config, and the flag-off payout experience all behave as designed.

Two things I would still do, neither of which blocks a supervised beta:

1. **Prove notification delivery end to end** before relying on pushes for retention — the permission plumbing is now correct, but no push has been observed arriving on a device in either session.
2. **Resolve M4** (the two M-Pesa surfaces) before providers onboard at any volume, so nobody believes they are payable when they are not.

And one launch-sequence rule that has not changed: **set `PAYOUT_OTP_PEPPER` before `PAYOUT_DESTINATIONS_ENABLED=true`.** The flag is verified **off** — `PAYOUT_DESTINATIONS_ENABLED` is absent from the Render environment entirely, checked at the source this round rather than inferred from a 503.

### What is the oldest Android version this release actually supports?

**Android 7.0 Nougat (API 24)** — declared in the APK, confirmed on-device, and consistent with every dependency in the tree (the build itself is the proof, since AGP refuses a minSdk below any library's floor).

**But "supported" here means "Play will install it", not "verified to work".** The oldest version *verified working* is **Android 12 (SDK 31)** on the A21s, and the primary verification device is **Android 13 (SDK 33)**. Android 7/8/9 were not tested, and there is a specific unresolved TLS trust-anchor question on Android 7.x that would break every network call if it bites. Either test one Android 7 device or raise the floor to API 26 as a deliberate, separately-evidenced decision.
