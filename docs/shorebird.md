# Shorebird — over-the-air updates for the Android app

Status: **live since 2026-11-07.** The current release is **`1.0.12+13`**
(v1.0.12, PR #13 merge `af8ae1c`, Flutter 3.44.9), registered with Shorebird
on 2026-11-13: APK 84,986,212 bytes, sha256 `eae85178…cdf9f`, signer
`48f1d72b…`, engines for all three ABIs, permissions identical to 1.0.11. It
carries the light launcher icon with a themed-icon layer, the amber
notification silhouette (`ic_stat_help24`), a splash that follows the phone's
theme, and the pill in-app banner, all checked on the S20+ before merging.
**Patch 1** (2026-11-14, stable, from `d81a691`, PR #15): Message Help24 photos
edge to edge with the time on the photo, and Profile complete on its first
frame. Icon check against `af8ae1c`: none added or removed; no asset diffs.
Phone-checked on the published APK (`patches/1` active). **Patch 2**
(2026-11-14, stable, from `191e585`, PR #20): Message Help24 photos kept in
their own cache on the phone (keyed by message, not by the hourly signed
link), so they download once; no icons, no asset diffs; `patches/2` active on
the published APK. **Published 2026-11-14** (§3 done): GitHub release
`v1.0.12` (Latest, tag at `af8ae1c`, asset `app-release.apk`, digest matches),
help24.co.ke via `help24_website@60c67e1` (download link checked: same size and
sha256); `ops.min_version` is being raised to 1.0.12 (soft and hard) by the
owner in App controls. The APK is kept at
`C:\Users\840 g8\Documents\Help24 releases\help24-1.0.12+13.apk`.

**Build note (2026-11-14):** four patch builds died when the WSL VM itself
stopped in the AOT step: Windows had about 5 GB of commit headroom left, and
the VM grows past that. With `GRADLE_OPTS="-Dorg.gradle.jvmargs=-Xmx2g
-Dorg.gradle.workers.max=2"` it builds. A crash mid-build can leave an empty
`configure_fingerprint.bin` under `~/.pub-cache/hosted/pub.dev/jni-*/android/.cxx`,
which fails the next build ("Was not a C/C++ structured log file"): delete
that `.cxx` folder. Long builds survive a `wsl.exe` client crash only when
started detached (`setsid nohup`). The fifth failure came with C: at 4.4 GB
free: Windows could not grow the page file, nor WSL its disk file. Removing
the old `~/h24build/sb-src-*` copies (prepare.sh recreates them; about 1.6 GB
each) gave the next build room inside WSL's disk, and it published.

**Do not patch 1.0.11 from main any more.** Main's notification code names
`@drawable/ic_stat_help24`, which only the 1.0.12 APK contains; a patch built
from main for 1.0.11 would ask Android for a drawable that release does not
have. 1.0.11+12 (`1b473b7`) keeps its Patches 1 to 7, and new work ships as a
patch to 1.0.12+13. `1.0.10+11` (`fae8c20`) was the first Shorebird release
and keeps its Patches 1 to 3. Patch lists are in docs/next-app-release.md. Each
release's `pubspec.lock` is kept in `~/h24build/shorebird/locks/<version>/`
for later patches.

**Check patches only on the published APK.** On 2026-11-08 the test phone was
found running a Windows arm64 build from another session. It is built with
stock Flutter, so it has no updater: no `[shorebird]` lines in logcat, and no
patch ever arrives. Reinstall the release APK (same signer and versionCode,
so the session is kept) before checking a patch.

Two things learned on the first run:

- `shorebird preview` runs in WSL, which cannot see a USB phone. Exposing the
  Windows adb server to WSL was refused as a safety measure. Until a release
  has members on it, testing on stable is equivalent; after that, use a
  custom track or wireless adb.
- `wsl.exe` expands `$VARS` in its argument string. Run Shorebird commands
  from a script file.

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
that warning as "this needs a full release", with one exception below.

### Asset diffs that are safe to allow (learned on 1.0.11 Patch 1)

Shorebird compares the patch's bundled files with the release's and refuses
on any difference. Two differences come from Dart changes alone:

- **The tree-shaken icon font** (`iconsax.ttf`, `MaterialIcons-Regular.otf`).
  It holds only the glyphs the code uses, so it changes whenever a screen
  starts or stops using an icon. A patch keeps the release's font. **Dropping
  icons is safe; adding one the release never used is not** (it renders
  blank). Check before allowing: compare `AppIcons.*` and `Iconsax.*` usages
  between the release commit and the patch commit (`git grep -hoE` over
  `mobile-app/lib`); the patch must add none.
- **`assets/l10n/en.json`.** A patch cannot change it, so any copy a patch
  needs must not depend on a new value there. Profile cases its labels in
  Dart (`_sentenceCase`) for this reason.

When both checks pass, publish with `shorebird patch ... --allow-asset-diffs`.
Note that `patch.sh` pipes through `tee`, so a refused patch can still print
exit 0: read the end of the log for "Not publishing".

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

**Done 2026-11-07.** Shorebird 1.6.138 in WSL (`~/.shorebird`), logged in
as alphwan14@gmail.com, app **Help24**, `app_id`
`e8c759a0-94da-4dcb-b4af-ca2447dae137` (in `mobile-app/shorebird.yaml`, which
is also a pubspec asset). `shorebird doctor`: no issues.

To redo it on another machine:

```bash
# WSL has no system unzip; the build toolchain's copy works
export PATH="$HOME/h24build/opt/unzip/usr/bin:$PATH"
curl --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/shorebirdtech/install/main/install.sh -sSf | bash
shorebird login            # prints a link; open it in the Windows browser
shorebird doctor
```

`shorebird init` needs `android/gradlew` and `android/local.properties`,
which git does not track. Run it in a scratch copy with the Gradle wrapper
copied in and `flutter pub get` done first, not in the Windows tree (it would
rewrite `.dart_tool` with Linux paths). Copy back only `shorebird.yaml` and add
`- shorebird.yaml` to the pubspec assets by hand: `init` re-serialises
`pubspec.yaml` and drops its comments. Its macOS entitlement fixes are not
needed; Help24 ships no macOS app.

`shorebird.yaml`'s `app_id` is not a secret; commit it. Never commit
`android/key.properties` or the keystore.

### What the scripts do for you

`scripts/shorebird/prepare.sh` (used by `release.sh` and `patch.sh`) mirrors
`~/h24build/scripts/build-release.sh`:

- source from `git archive <commit>`, never the working copy;
- the Gradle wrapper and `pubspec.lock` from the Windows working tree, because git
  does not track them. `release.sh` keeps the release's resolved lock in
  `~/h24build/shorebird/locks/<version>/`, and `patch.sh` builds against it,
  so a patch has exactly its release's dependencies;
- signing from the Windows `android/key.properties`, read into the
  environment (`HELP24_KEYSTORE_*`) and never written anywhere. Set
  `H24_KEY_PROPERTIES` only to use a different file, and its `storeFile` must
  be a WSL path;
- the JDK and Android SDK from `~/h24build/opt`.

Patch signing is on by default: the release embeds a key Shorebird manages,
and devices install only patches signed with it.

## 2. Pick the Flutter version

Shorebird builds with its own copy of a named Flutter version, and every
patch builds on its release's version automatically. Changing it is always a
full release. 1.0.10 was built on 3.44.4; **1.0.11 moved to 3.44.9** (same
Dart 3.12.2, Android hotfixes). The Shorebird CLI defaults to the newest
stable Flutter (3.47.x as of 2026-11-08), so always set it. Export it once
per shell:

```bash
export H24_FLUTTER_VERSION=3.44.9       # 1.0.11's and 1.0.12's Flutter; `shorebird flutter versions list` shows what is offered
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
