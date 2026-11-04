# Next app release — changes waiting on it

The changes below are merged on `main` but are **not on members' phones** until
the next Android release. Published today: **v1.0.9** (versionCode 10, release
commit `367c367`). The next release must be **≥ 1.0.10+11** — check
`gh release list` first; parallel sessions have shipped versions before.

Keep this file current: add a row when a change to `mobile-app/` lands, and
clear the table (moving it under "Shipped in …") when a release goes out.

Build in WSL from a commit, never from Windows:
`wsl -d Ubuntu -- bash -lc 'bash ~/h24build/scripts/build-release.sh <commit>'`
(see the wsl-release-build notes). Windows builds are arm64-only test builds.

## Waiting for release

| Commit | Change | Why members need it | Verified |
|---|---|---|---|
| _(this commit)_ | The approve screen says when an unanswered job **approves automatically** (`auto_approve_at`, backend migration 134) | Without it the client learns of the 48 h window only from the pushes; 1.0.9 still gets the reminders and routes them to this screen | Unit + widget test (`test/auto_approve_test.dart`) |

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
