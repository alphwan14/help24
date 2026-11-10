# Next app release — changes waiting on it

The changes below are merged on `main` but are **not on members' phones** yet.
Current release: **v1.0.11** (versionCode 12, release commit `1b473b7`,
Flutter 3.44.9), published 2026-11-08.

A Dart-only change ships as a **patch** to installed phones of the current
release (`scripts/shorebird/patch.sh`, docs/shorebird.md), with no new APK and
no version bump. Patches now target **1.0.11+12**; 1.0.10 phones keep their
Patches 1 to 3 and get nothing newer until they install 1.0.11. A full release
is needed only for native code, assets, permissions, plugins or a Flutter
upgrade; the next one must be **≥ 1.0.12+13**. Check `gh release list` first;
parallel sessions have shipped versions before.

Keep this file current: add a row when a change to `mobile-app/` lands, and
clear the table (moving it under "Shipped in …") when a release goes out.

Build in WSL from a commit, never from Windows:
`wsl -d Ubuntu -- bash -lc 'bash ~/h24build/scripts/build-release.sh <commit>'`
(see the wsl-release-build notes). Windows builds are arm64-only test builds.

## Waiting

Nothing for a full release. `ops.min_version` goes to 1.0.11 (block), set by
the owner from the admin dashboard on 2026-11-08.

Bundled-file changes on `main` that a patch cannot carry, so they wait for
1.0.12: `assets/l10n/en.json` sentence-case labels (Profile already cases
them in Dart, so nothing looks wrong meanwhile).

## Patches on 1.0.11 (stable)

Checked on the S20+ running the published v1.0.11 APK (sha `84c88140…`).

| Patch | Commit | Change | Verified |
|---|---|---|---|
| 1 | `6bc76f5` (`a25e7b4` + label casing) | Profile redesign: "Complete your profile" setup row (4 steps, payout step left out while payout numbers are off), Payments screen merging Payment number and Payout destinations, Business rows by provider state, stats only after a completed job, account status banner, text footer, 52 px rows, sentence case, em dashes removed from touched copy | 1627 tests. Published 2026-11-08 17:05 (about 1.3 MB per ABI). On the S20+ running the published APK: start 1 downloaded and installed patch 1, start 2 verified its signature and ran it (`active path …/patches/1`); Profile shows "2 of 3", Payments, the text footer, sentence-case labels despite the old en.json, and "Help24 v1.0.11". First attempt was refused by Shorebird for asset diffs (en.json, tree-shaken iconsax.ttf); republished with `--allow-asset-diffs` after checking the patch adds no icons (docs/shorebird.md). A second attempt died when WSL ran out of memory (idle Gradle daemons); `prepare.sh` now turns the daemon off |
| 2 | `0c46e15` (PR #8, merged as `7e5518b`) | Picture-first Discover: a photo only on posts that have one, rows without a hairline; the Post button and the search row hide on scroll down and return on scroll up. Also carries the never-published `78ac4f8` fixes (no em dashes in the UI, Payments without the flicker, one Promote button, Sign out hugs its word, "Get ready to work") | 1634 tests (3 known WSL-mirror failures). Checked on the S20+ as a release-signed test build first. Published 2026-11-09 with `--allow-asset-diffs` (only en.json from Patch 1 differs; 0 icons added vs `1b473b7`), log ends "Published Patch 2!" with no "Not publishing". On the published APK: signature valid, `active path …/patches/2`, Discover shows the new rows |
| 3 | `a4681c3` (local `git am` of PR #9, same tree as `5b9a3c9`; merged as `398d58e`) | A hairline between Discover rows (the one allowed exception to the no-divider gate, scoped to `listing_card.dart`), and on the author's own post the My Offer / Manage / Applications button becomes a quiet chip: "Your offer", "Your request" or "N offers" | Published 2026-11-09 to stable. Checked 2026-11-10 on the S20+ running the published APK (sha `84c88140…`): `active path …/patches/3` on two starts, no newer patch offered; Discover shows the hairline between rows, and Activity's own-post rows show "Your request" / "Your offer" chips with no button |
| 4 | `896dafc` (PR #10) | Payment protection fee: 5% of the job, minimum KES 30, maximum KES 1,000, shown before payment (`payment_utils.dart`, the same golden table as `backend/src/mpesa/fee.ts`). The fee row is renamed "Payment protection" on the payment screen and the receipt | App fee and plain-copy tests pass; `flutter analyze` clean. Published 2026-11-10 to stable with `--allow-asset-diffs` (the same en.json and tree-shaken iconsax.ttf diffs as Patches 1 to 3; 0 icons added). Log ends "Published Patch 4!". Running on the S20+ (published APK, sha `84c88140…`) on 2026-11-11: `active path …/patches/4` at the first start of the Patch 5 check below |
| 5 | `18547e6` (PR #11) | First-launch terms screen every install accepts once (versioned `TermsAcceptance`, between Home and the splash; startup prompts wait for it). Materials Advance switch on the payment screen and "Send materials money" on the job screen (hidden while the backend switch is off). Providers read "Only jobs paid through Help24 earn reviews" | Targeted app suites pass; full suite only the 3 known WSL-mirror failures. Published 2026-11-11 to stable with `--allow-asset-diffs` (same en.json and iconsax.ttf diffs as before; 0 icons added). Log ends "Published Patch 5!". Checked 2026-11-11 on the S20+ running the published APK (sha `84c88140…`): start 1 ran patches/4 and downloaded patch 5 (signature valid), start 2 `active path …/patches/5` showed "Before you start"; I agree opened Discover with the feed already loaded; start 3 went straight to Discover (handover at feed ready, +1649 ms), updater "No update". The payment screen's "Payment protection" row was not opened on the device |

## Shipped in 1.0.11 (2026-11-08)

Release commit `1b473b7`, tag `v1.0.11`: 84,776,447 bytes, sha256
`84c88140…9714` (matches GitHub), cert `48f1d72b…`, all three ABIs with the
engine, permissions identical to 1.0.10, `shorebird.yaml` bundled. Built with
`scripts/shorebird/release.sh` (Shorebird 1.6.138, **Flutter 3.44.9**, up from
3.44.4). Website `help24_website@eaf7b90` serves it. App code is the same as
1.0.10 with Patches 1 to 3. On the S20+ it installed over a test build as
1.0.11 (versionCode 12), stayed signed in, loaded Discover, Messages and
Profile, and the updater reported `release_version changed 1.0.10+11 ->
1.0.11+12` and checked the stable channel. Right after upload, GitHub's public
asset link answered 504 for several minutes while the API served the file;
it then redirected normally.

## Patches on 1.0.10 (all on stable)

A phone gets the latest patch at its first start after it is published, and
runs it from the next start. Checked on the S20+ running the published
v1.0.10 APK (sha `915baef5…`). A Windows arm64 test build has no Shorebird
engine and never receives patches, so never check a patch on one.

| Patch | Commit | Change | Verified |
|---|---|---|---|
| 1 | `9d6e1f9` | Discover pages 30 at a time; feed thumbnails decode at 384 px | Downloaded on one start, booted on the next; ranked `n=30` |
| 2 | `4f1e3d8` | Minimal UI: no divider lines; post detail reworked as type (from another session) | 1614 tests on a clean copy; on the phone, active path `patches/2`, and the post detail shows the redesign |
| 3 | `84f582a` | Feed cards load a small JPEG made at upload (`posts/<id>.thumb.jpg`, about 37 KB instead of about 190 KB) | 1622 tests; Shorebird reported no native or asset diffs; the phone check was pending when this was written |

The 49 photos from before Patch 3 were given thumbnails on 2026-11-08, with
the owner's approval (`mobile-app/tool/backfill_post_thumbnails.dart`: 9.3 MB
of photos, 1.8 MB of thumbnails, 0 failed). A re-run found nothing to do.

## Shipped in 1.0.10 (2026-11-07)

Release commit `fae8c20`, tag `v1.0.10`: 81,407,359 bytes, sha256
`915baef5…3edc` (matches GitHub), cert `48f1d72b…`, all three ABIs with the
engine, permissions identical to 1.0.9, `shorebird.yaml` bundled. Built with
`scripts/shorebird/release.sh` (Shorebird 1.6.138, Flutter 3.44.4). Website
`327f56d` serves it. `ops.min_version` not changed (owner's call).

On the S20+ it installed over the published 1.0.9 (Play Protect ALLOW) and
stayed signed in. The Shorebird updater checks app `e8c759a0…`, release
`1.0.10+11`, stable channel. Checks passed: Verify your identity opens (live
status); Offer → Babysitting shows "Care check needed" before the form;
Discover → All includes a job; Messages loads.

| Commit | Change | Why members need it | Verified |
|---|---|---|---|
| `9418f8e` | The approve screen says when an unanswered job **approves automatically** (`auto_approve_at`, migration 134) | Before, the client learned of the 48 h window only from the pushes | Unit and widget test (`test/auto_approve_test.dart`) |
| `46e0322` `a2e1d46` `441f77b` | **Verify your identity** (Profile → Business), the ID and Care check upload flow, a sheet as soon as a vetted category is picked, listing labels, verification notifications, plain copy (docs/provider-vetting.md) | Without it a provider in a vetted category is refused by the database with no way to verify | `flutter analyze` clean in branch code; `flutter test` 1609 passed (3 environmental); on the S20+ (provider-vetting.md § Rollout log). No document upload was exercised in production |
| `8f49bd8` | Shorebird app id | Patches without reinstalling | — |

### Patch 1 (stable, 2026-11-07)

`9d6e1f9`, the first patch: Discover pages 30 at a time, and feed thumbnails
decode at 384 px instead of the 1200 px upload (about 0.5 MB of memory each
instead of 5.8 MB). It was staged, then promoted to stable with the owner's
approval while the test phone was the only 1.0.10 install.

On the S20+: start 1 ran the release code, found Patch 1 and downloaded
617 KB. Start 2 verified its signature and booted it. The feed then
installed `posts=30` from a ranked `n=30` request, plus the patch's new
one-line fallback log. Every phone that installs 1.0.10 gets Patch 1 at its
first start and runs it from the second.

## Shipped in 1.0.9 (2026-11-04)

Release commit `367c367`, tag `v1.0.9`: 74,582,185 bytes, sha256
`47a1c71f…32ad` (matches GitHub), cert `48f1d72b…`, all three ABIs,
permissions identical to 1.0.8. On the S20+ it installed over 1.0.8 (Play
Protect ALLOW, still signed in); website `68b242e` serves it. `ops.min_version`
not changed.

| Commit | Change | Why members need it | Verified |
|---|---|---|---|
| `fbdb8d6` | Request alerts get their own icon and a **Send an offer** action | The alert says what to do | Before this audit |
| `68ec4eb` | Chat photos are typed by their bytes, not their file name | **Ordinary PNG photos (and HEIC) can never be sent in chat on 1.0.8** — permanent 415 `CONTENT_MISMATCH`, "Not sent" forever | Unit tests red→green; on a phone the stuck photo sent itself after the update |
| `d87dfc2` | An offer with no price reads "sent an offer", not "offered KES <budget>" | The job bar quoted a price the provider never named | Unit test red→green; on a phone |
| `2299157` | A message deleted for everyone leaves the conversation list preview | The deleted text stayed visible in both people's lists | On a phone (server preview + receiver's list) |
| `c40314c` | Back / Save / Delete on the post screen and the photo composer's Send are named for screen readers | TalkBack announced only "Button", including on Delete | Widget test red→green; content-desc on a phone |
| `5ba11f5` | A tap on a chat push that **starts** the app opens that chat | **On 1.0.8 every such tap — after a reboot, a swipe-away, or Android reclaiming the app — lands on Discover** | Contract test red→green; on a phone after a reboot/kill (see the audit report) |
| `6e901e6` | Discover **All** includes **jobs** (`FeedScope.all`) | Owner decision 2026-10-29: "All" should mean all; a search for "cleaner" missed a cleaning job | Unit tests; backend half already live — see below |
| `1268007` | **My Help24 card** (Profile → Business): card + QR + share; `help24.co.ke/p/<id>` opens the provider's profile (docs/provider-card.md) | Providers bring their own customers; 1.0.8 does not claim `/p/` links | Unit + widget tests; S20+ on the release APK: card renders, QR decodes from a screenshot to the right link, share sheet carries the PNG, warm and cold App Link open the profile after the launch hold, agent links still route |
| | Discover **All** (row above) | | Also seen on the S20+ release APK: the open Mtwapa Gardens job is in All |

### The one change with a server half

"Jobs in All" has two halves. The **backend** half (`typesForScope('all')`
includes `job`) deploys with the backend and is harmless to 1.0.8: that app
filters "All" to requests and offers on its own side, so it simply keeps
showing what it showed. Jobs appear under "All" only once the app half ships.
Never ship the app half against a backend without the server half — the
ranked feed and the fallback would then disagree, which is exactly what
`mobile-app/lib/utils/feed_scope.dart` exists to prevent.

## Before building the release

1. Re-run the full suite in WSL (`~/h24build/scripts/wsl-test.sh`). Known
   environmental failures: design_tokens_export ×2, trust_safety_test load.
2. On both test phones after installing over 1.0.8: send a PNG photo in a chat
   (it must deliver), open a chat whose offer has no price (no amount quoted),
   delete a message for everyone (the list shows "This message was deleted"),
   open Discover → All (jobs appear), TalkBack on a post screen (Back/Delete
   are named).
3. Decide whether to raise `ops.min_version` (App controls). The PNG fix is the
   strongest reason: on 1.0.8 those photos fail permanently.

## Open findings to consider for the same release

These are not fixed yet — each is in `docs/prelaunch-audit-2026-10-29.md`:

- **Single-device push purge** (`user_profile_service.dart`, "Step 2"): after
  every registration the app deletes the member's other Android tokens, so
  someone signed in on two phones gets pushes only on the last one to
  register. The backend already prunes dead tokens on send failure; removing
  Step 2 restores multi-device delivery.
- The live journey is not scoped to an account and survives sign-out.
- "Delete post?" promises the photos are deleted; the post is archived and its
  photo stays publicly served.
- The conversation list calls a queued message "Not sent".
- Accept (select provider) and Delete for everyone have no confirmation.
- Release builds log every feed post (`📦 Post:`).
