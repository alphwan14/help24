#!/usr/bin/env bash
# Shorebird RELEASE: a full APK that members install once, and that later
# Shorebird patches apply to. See docs/shorebird.md.
#
#   bash scripts/shorebird/release.sh <commit>
#
# Run in WSL (like the normal release build), from any directory. Needs:
#   * the Shorebird CLI on PATH, logged in (`shorebird login`, once);
#   * mobile-app/shorebird.yaml committed (`shorebird init`, once);
#   * the upload keystore config the normal release uses: set
#     H24_KEY_PROPERTIES to its key.properties (default ~/h24build/key.properties).
#
# It builds from a CLEAN checkout of <commit> in a temporary worktree, never
# from your working copy, so what Shorebird stores as the release is exactly
# that commit — patches are later diffed against it.
set -euo pipefail

COMMIT="${1:?usage: release.sh <commit>}"
REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
KEY_PROPS="${H24_KEY_PROPERTIES:-$HOME/h24build/key.properties}"
# The Flutter version the last normal release was built with. Shorebird builds
# with its own copy of exactly this version; a different one changes the
# engine and would not match later patches.
FLUTTER_VERSION="${H24_FLUTTER_VERSION:-}"

command -v shorebird >/dev/null || { echo "shorebird CLI not found — see docs/shorebird.md §1"; exit 1; }
# Signing: the same upload key as every Help24 release. Either a key.properties
# (its storeFile must be an ABSOLUTE path, since it is copied into a temporary
# checkout) or the HELP24_KEYSTORE_* variables android/app/build.gradle reads.
if [ ! -f "$KEY_PROPS" ] && [ -z "${HELP24_KEYSTORE_PATH:-}" ]; then
  echo "No signing key: set H24_KEY_PROPERTIES to key.properties, or export HELP24_KEYSTORE_PATH/PASSWORD/ALIAS/KEY_PASSWORD"
  exit 1
fi
[ -n "$FLUTTER_VERSION" ] || { echo "Set H24_FLUTTER_VERSION to the Flutter version of the last release (flutter --version), e.g. 3.27.4"; exit 1; }

WORK="$(mktemp -d /tmp/h24-shorebird-release-XXXX)"
trap 'git -C "$REPO" worktree remove --force "$WORK" >/dev/null 2>&1 || true' EXIT
git -C "$REPO" fetch --quiet origin
git -C "$REPO" worktree add --detach "$WORK" "$COMMIT" >/dev/null

cd "$WORK/mobile-app"
[ -f shorebird.yaml ] || { echo "mobile-app/shorebird.yaml is missing at $COMMIT — run 'shorebird init' and commit it first"; exit 1; }
[ -f "$KEY_PROPS" ] && cp "$KEY_PROPS" android/key.properties

VERSION="$(grep -E '^version:' pubspec.yaml | awk '{print $2}')"
echo "Releasing Help24 $VERSION from $(git rev-parse --short HEAD) with Flutter $FLUTTER_VERSION"

shorebird release android --artifact apk --flutter-version="$FLUTTER_VERSION"

APK="build/app/outputs/flutter-apk/app-release.apk"
[ -f "$APK" ] || { echo "APK not found at $APK"; exit 1; }
OUT="$HOME/h24build/out/help24-$VERSION-shorebird.apk"
mkdir -p "$(dirname "$OUT")"
cp "$APK" "$OUT"
echo
echo "Release APK: $OUT"
echo "  size:   $(stat -c %s "$OUT") bytes"
echo "  sha256: $(sha256sum "$OUT" | awk '{print $1}')"
echo
echo "Next (docs/shorebird.md §3): publish it as the GitHub release and on help24.co.ke"
echo "(npm run sync:release in help24_website), then raise ops.min_version to $VERSION"
echo "so every member installs this build once."
