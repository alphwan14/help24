# Launch Readiness Verification Report

**Date:** 2026-08-08
**Device:** Samsung SM-A217F (Galaxy A21s), Android 12 / SDK 31, physical device over ADB (`R58N624CD2J`). No emulator.
**Build:** `flutter build apk --release` from commit `010bd63`, 68.7 MB, installed via `adb install -r`. No dart-defines — `ApiConfig.baseUrl` resolved to the production default.
**Backend:** `help24-backend` (srv-d7mjm2v7f7vs73f8qaqg), deploy `dep-d9r4dsrbc2fs739ar7ig`, commit `010bd63`, status live.
**Method:** every UI action driven by `adb input`, every screen captured by `adb exec-out screencap`, every action correlated against Render app logs by `requestId`. No claim below is made from code reading alone.

---

## Verdict first

**Help24 is technically ready for controlled beta testing** — with **one configuration change that must happen before payouts are enabled**, and **one client fix I would want before inviting real users**.

Nothing found is an architecture defect. The freeze holds: every finding is a config sequencing issue, a client-side UX gap, or log hygiene. No finding requires new backend infrastructure.

---

## CRITICAL

### C1 — Payout-destination routes accept unauthenticated callers asserting any `user_id`

**Evidence (production, requestId `0a3605fd-d5d4-4bc6-b90d-00b78eec6f56`):** an unauthenticated `curl` POST to `/payout-destinations` with a body naming another person's uid was accepted by the auth guard and reached the controller. The access log records:

```
"userIdSource":"asserted"      ← not "verified"
"authWouldDeny":"absent"       ← the guard would have denied it, and did not
"authScheme":"firebase"
"rateLimitPolicy":"payout:issue"
```

The request was stopped only by the `503` feature flag, not by authentication. Production runs `AUTH_ENFORCEMENT=enforce` **narrowed to `enforceOnly=[/PROMOTIONS]`**, so every other `@Auth` route — including the entire payout-destination API — still runs in monitor behaviour.

**Why this is critical:** the moment `PAYOUT_DESTINATIONS_ENABLED=true` is set, this API decides where money is sent. Without enforcement, an unauthenticated caller could add a payout destination to a victim's account naming their own phone, receive the OTP on that phone, verify it, and make it the default — redirecting that provider's earnings. The OTP proves possession of the phone; it does not prove the requester owned the account.

**Not currently exploitable.** The feature is disabled and returns 503 before any handler logic runs. This is a sequencing trap, not a live hole.

**Fix (env only, no code, no deploy):** add `/payout-destinations` to `AUTH_ENFORCE_ONLY` — or move to full enforcement — **and verify with the same curl probe returning 401** *before* setting `PAYOUT_DESTINATIONS_ENABLED=true`. These two env changes must be made in that order, ideally in the same maintenance window.

**Supporting evidence that full enforcement is now safe:** every single request the real device made during this session carried `userIdSource:"verified"` — feed, reputation, interactions, payout reads. Zero `authWouldDeny` lines were produced by the app. The client migration that enforcement was waiting on is complete, at least for the flows exercised here.

---

## HIGH

### H1 — The app believes notifications are enabled while the OS has them blocked

**Evidence:** `adb shell dumpsys notification` reports `AppSettings: com.help24.help24 (10370) allowNoti=false`. The app nonetheless logged `[FCM][TOKEN] saved for uid=…` and registered its token with the backend, because `_requestPermission()` (notification_service.dart:424) treats FirebaseMessaging's `authorizationStatus` as truth — and on Android 12 that status is `authorized` regardless of the user's actual notification toggle, since runtime permission did not exist before Android 13.

**Consequence:** the server sends pushes, the OS silently drops them, and neither the user nor the system has any signal. For a marketplace where a provider learns about a job by notification, silent delivery failure is a retention bug that looks like "nobody is hiring".

**Also untested:** the Android 13+ runtime `POST_NOTIFICATIONS` prompt. The manifest declares the permission, but this device is SDK 31, so the prompt path could not be exercised. Most new devices are 13+.

**Fix (client only):** check actual notification-enabled state (`areNotificationsEnabled()` via permission_handler or the plugin's platform check) rather than trusting `authorizationStatus`, and show an in-app nudge that deep-links to system settings when off. Re-test on an Android 13+ device before beta.

---

## MEDIUM

### M1 — Expected feature-flag 503s are logged at ERROR level
Three `ERROR`-level lines were produced by ordinary user navigation in a 15-minute session (`GET /payout-destinations 503`), each logged twice — once by `AllExceptionsFilter`, once by the HTTP logger. The error log is the signal this project uses to judge production health; a disabled feature that a user simply visited should not consume it. Log expected feature-gate responses at `warn` or `info`.

### M2 — Cold start issues three `/feed` requests within one second
`21:15:57.334` (1004 ms), `21:15:57.807` (147 ms), `21:15:58.258` (148 ms) — three separate `GET /feed` calls on the launch path, plus two more 90 ms apart on a later navigation (`21:23:37.024`, `21:23:37.114`). On Kenyan mobile data this is wasted payload and battery on the most latency-sensitive path in the app.

### M3 — Reputation is fetched N+1 despite a batch endpoint existing
The client calls `GET /reputation/:providerId` once per visible card (four calls per feed render observed at `21:20:12.207/.221/.388` and again at `21:23:37.468/.533/38.045`) while *also* calling the batch `GET /reputation`. On a 20-card feed this is up to 20 avoidable round trips. `reputation_service.dart:376` is the individual call site.

### M4 — Two competing M-Pesa number surfaces now exist
Account → **Payment Settings** (legacy: writes `users.phone_number` straight to Supabase, biometric-gated) sits alongside Business → **Payout Destinations** (new: verified destinations that actually govern payouts). Captured on device: the legacy sheet still says "This number is used for M-Pesa payments and payouts." A provider can set a number there and reasonably believe they are payable when they are not. One of the two must become the single source of truth before providers onboard for real.

### M5 — The provider gate and the onboarding hub do not know about each other
Tapping "Offer Service" shows the older "Complete your professional profile" sheet, which routes to Professional Profile and points at "Account → Payment Settings" — it never mentions the new "Become a Provider" hub or payout verification. Two parallel onboarding entry points telling different stories. (This is item P1 in `provider-experience-sprint.md`, now confirmed on device rather than assumed.)

---

## LOW

- **L1** — One `POST /feed/interactions` took 1267 ms against a ~85 ms median. Single occurrence; consistent with free-tier database variance. Worth re-checking after the plan upgrade rather than acting on now.
- **L2** — Frame-level jank could not be instrumented: `dumpsys gfxinfo` reports 0 frames and `SurfaceFlinger --latency` returns empty rows for Flutter's BLAST SurfaceView layer on this device. Scrolling was subjectively smooth and no ANR or slow-frame warning appeared, but I have **no measured jank percentage** and will not invent one. Use a `--profile` build with DevTools if a number is required.
- **L3** — Backend validation messages are developer-shaped (`property garbage should not exist; user_id should not be empty; …`). They never reach users today — ErrorMapper's clean-message filter rejects anything over 120 characters or containing technical markers — but they would be unhelpful if ever surfaced.

---

## PASSED — verified working

**Launch & session**
- Cold start `TotalTime: 2024 ms`, warm start `TotalTime: 144 ms`.
- Session restored silently from a previous install — no re-login (`uid=bLbPkk9w2uSX8sLbgvjw2wMBOPb2`).
- Splash held until the feed was real: `[FEED_INSTALL] +3795ms gen=2 source=ranked placeholder=false posts=20 splashUp=true`, then `[LAUNCH] +3847ms lifted` — the launch-transaction contract holds on a real mid-range device.
- Firebase token refresh observed working: `[AUTH][BRIDGE] 401 → token refreshed, replaying request`.

**Remote config**
- `GET /config` → 200 with `etag: W/"3b6c0888a44bf4c1"` and `Cache-Control: public, max-age=60`; conditional `If-None-Match` → **304**. Kill switches, maintenance, min_version and announcement all present and inactive as configured.

**Feed**
- 20 ranked posts server-side, images, avatars, reputation stars, locations, "New Provider" badges, relative timestamps.
- Pull-to-refresh reinstalled cleanly (`gen=4 source=ranked`).
- Filters work with contextual copy — "Requests" narrowed to 14 posts, search placeholder became "Search requests…", CTA became "Offer Service".
- Interaction telemetry accepted: `POST /feed/interactions 202`.

**Provider & payouts (the new work)**
- Onboarding hub renders 3 steps with live completion tracking ("0 of 3 steps complete").
- **Disabled-flag behaviour is exactly as specified**: Step 3 reads *"Rolling out soon. Your other steps still count."* with no tappable action; the Payout Destinations screen shows *"Not available yet — Payout number verification is being rolled out. Check back soon — your earnings are unaffected."* No crash, no raw error, no stack trace, no dead end.
- Backend correlation confirms the new plumbing: `route:/payout-destinations`, `rateLimitPolicy:payout:read`, `authScheme:firebase`, `userIdSource:verified`, latency 1.4–6 ms.
- Provider gate correctly intercepts "Offer Service" for an incomplete profile with an explanatory sheet.

**Offline & recovery**
- Airplane mode: "No internet connection" banner appears, **cached feed stays on screen** — the frozen-snapshot contract held, no wipe to empty.
- New payout screen offline: *"We couldn't load this / We couldn't reach the internet. Please try again."* with a working **Retry** — ErrorMapper routing confirmed on new code.
- Reconnect: realtime resubscribed automatically (`RealtimeSubscribeStatus.subscribed`), Retry transitioned straight to the correct 503 state.

**Stability**
- **Zero crashes, zero ANRs, zero `E/flutter` errors** across the entire session (`adb logcat -b crash` empty, `/data/anr/` empty).
- Memory: 149.9 MB TOTAL PSS, 51.8 MB native heap, 1 activity, 0 WebViews — no leak signature over ~20 minutes of navigation.

**Backend health during testing**
- No 5xx other than the intentional 503s. Every other request 200 or 202.
- Event processor alive throughout, `queueSize=0`, ticking every 60 s; promotions sweep running. Dead letters stayed at 1 (the known June artifact).
- Database 107–487 ms, Firebase 40–41 ms.
- Admin self-check on the new deploy: *"✓ 3 active admin(s) … No bootstrap account exists — fully hardened."*
- Route audit: `117 routes — firebase=45 admin=49 public=23 undeclared=0`.

---

## Corrections to earlier claims

**B1 in `launch-readiness-sprint.md` was wrong and is withdrawn.** `api_config.dart:22` already defaults to `https://help24-backend.onrender.com`; the LAN-IP hardcode was fixed previously. A release APK built with no flags talks to production — proven by this device session. That blocker should not have been listed.

---

## If Help24 were submitted to the Play Store today

Two things before the first real users:

1. **Sequence the payout enablement correctly (C1).** Add `/payout-destinations` to `AUTH_ENFORCE_ONLY`, re-run the unauthenticated curl probe and confirm 401, and only then consider `PAYOUT_DESTINATIONS_ENABLED=true`. Today the feature is off, so nothing is exposed — but these two switches must never be flipped in the wrong order.
2. **Fix notification enablement detection (H1)** and re-test on an Android 13+ device. Beta testers who never receive a job notification will conclude the marketplace is empty.

Everything else is polish that can ship during the beta. M4 (two M-Pesa surfaces) should be resolved before providers onboard at any volume, but it does not block a controlled beta where onboarding is supervised.

**Declaration: Help24 is technically ready for controlled beta testing**, conditional on item 2 above being fixed and item 1 being respected as a launch-sequence rule.
