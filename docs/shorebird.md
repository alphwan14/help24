# Shorebird — over-the-air updates for the Android app

Status: **set up in the repository, not yet run.** The scripts and this runbook
are in place. Nothing changes for members until step 3 (the first Shorebird
release) goes out.

## What it does, in one paragraph

Today every app change needs a new APK that each member downloads from
help24.co.ke and installs over the old one. With Shorebird, one more APK is
built with `shorebird release` and installed once. After that, Dart-only
changes (almost all of the app: screens, copy, logic, bug fixes) ship as
**patches**: the app checks for one at start-up in the background, downloads
it while the member uses the app, and runs the patched code **from the next
time the app starts**. No prompt, no download page, no reinstall. It works the
same for the sideloaded APK as it will on the Play Store.

## What a patch can and cannot change

| Can be patched | Needs a new APK (full release) |
|---|---|
| Any Dart code in `mobile-app/lib` — screens, copy, flows, fixes | Native code: Kotlin/Java in `android/`, `MainActivity.kt`, the manifest, permissions, App Links |
| New pure-Dart packages | A plugin with native code that the release did not already include |
| Dart defines | Assets: images, fonts, bundled JSON in `assets/` |
| Translations generated as Dart | A Flutter upgrade; the app icon; `versionCode` |

The migration-135 vetting screens use only `image_picker` and `file_picker`,
which 1.0.9 already contains, so they could ship as a patch to a Shorebird
release. They will go out with the first Shorebird release (1.0.10) itself.

`shorebird patch` warns when a change touches native code or assets. Treat
that warning as "this needs a full release".

## Free plan (checked 2026-11-07, shorebird.dev/pricing)

| | Hobby (free) | Pro ($20/month) |
|---|---|---|
| Patch installs per month | **5,000** | 50,000, then $1 per 2,500 |
| Apps and releases | Unlimited | Unlimited |
| Team | Owner only | Roles (Admin, Developer, Viewer) |
| Rollbacks, signed patches, staging track, console | Included | Included |
| Support | Community Discord | — |

A **patch install** is one device successfully applying a patch. A device that
skips several patches and installs the latest pays for one. Five patches in a
month to 1,000 active phones is 5,000. With overage off, patches stop
installing for the rest of the month once the allowance is used. Shorebird
documents this for paid plans with overage turned off, and the free plan has
no overage. Members simply keep the last patch they had, and nothing breaks.
At Help24's size today the free plan is enough; Pro is the step when monthly
active phones × patches passes about 5,000.

## 1. One-time setup (owner's machine, WSL)

```bash
# Install the CLI (it brings its own Flutter; your normal Flutter is untouched)
curl --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/shorebirdtech/install/main/install.sh -sSf | bash
shorebird login            # opens a browser; uses your Shorebird account
shorebird doctor

cd ~/path/to/help24/mobile-app
shorebird init             # creates shorebird.yaml (app_id) and adds it to pubspec assets
git add shorebird.yaml pubspec.yaml && git commit -m "chore(app): Shorebird app id"
```

`shorebird.yaml`'s `app_id` is not a secret; commit it. Never commit
`android/key.properties` or the keystore.

## 2. Pick the Flutter version

Shorebird builds with its own copy of a named Flutter version. Use the one the
1.0.9 release was built with (`flutter --version` in the WSL build
environment). Export it once per shell:

```bash
export H24_FLUTTER_VERSION=3.x.y        # what `flutter --version` prints
export H24_KEY_PROPERTIES=~/h24build/key.properties   # storeFile must be an absolute path
```

## 3. The first Shorebird release (1.0.10) — members install this once

```bash
bash scripts/shorebird/release.sh <commit>     # commit with version: 1.0.10+11
```

The script builds from a clean checkout of `<commit>`, signs with the usual
upload key, registers the release with Shorebird, and prints the APK path, size
and sha256. Then:

1. Run the usual checks from `docs/next-app-release.md` on the test phones.
2. Publish the APK as the GitHub release `v1.0.10` and on help24.co.ke
   (`npm run sync:release` in `help24_website`), as for any release.
3. **Raise `ops.min_version` to 1.0.10** (admin dashboard → App controls). Older
   apps are held at the update screen and their owners install 1.0.10 once.
   This is the last time anyone has to.

## 4. Shipping a fix as a patch

Keep `version:` in `pubspec.yaml` at the release's version. A patch targets
the release with that version.

```bash
bash scripts/shorebird/patch.sh <commit>            # staging track — nobody gets it yet
```

Check it on a test phone (USB debugging on, `adb devices` lists it):

```bash
shorebird preview --track staging --app-id <app_id> --release-version 1.0.10+11
```

Close the app fully (swipe it away) and open it again. The patch runs from that
start. When it is right:

```bash
shorebird patches set-track --release-version 1.0.10+11 --patch-number <n> --track stable
```

Every phone on 1.0.10 picks it up at its next start and runs it from the start
after that. A bad patch is rolled back from the Shorebird console. Phones go
back to the release code (or the previous patch) at their next start.

## Will it be clean for members?

- **No re-download, no prompt.** After the one-time 1.0.10 install, patches
  arrive silently.
- **One delay to expect:** a patch runs from the *second* start after it is
  published. The first start downloads it in the background; the next start
  runs it. Someone who leaves Help24 open in the background for days gets it
  later. Android reclaims background apps regularly, so in practice that is
  usually within a day.
- **Offline is fine.** No connection means no patch check; the app runs as
  before and tries again next start.
- **Both apps' versions stay honest.** A patch does not change the version
  members see. `users.app_version` (migration 126) keeps reporting
  `1.0.10`. The Shorebird console shows how many phones run each patch.
- **`ops.min_version` remains the tool for native changes.** When a change
  needs a full release, ship an APK as today and raise the minimum.

## Optional, later: a "restart to update" nudge

`package:shorebird_code_push` lets the app ask whether a patch is downloaded
and offer "Restart to update", so a fix lands in minutes instead of at the
next natural restart. It is a pure-Dart package, so it can itself arrive in a
patch. Worth adding only if a fix ever needs to land faster than that.
