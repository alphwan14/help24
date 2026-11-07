#!/usr/bin/env bash
# Shorebird PATCH: ship a Dart-only fix to members on an existing Shorebird
# release, with no new APK. See docs/shorebird.md.
#
#   bash scripts/shorebird/patch.sh <commit>            # to the staging track
#   bash scripts/shorebird/patch.sh <commit> --stable   # straight to everyone
#
# Staging first is the default: a staged patch reaches only devices you point
# at it (shorebird preview), so it can be checked on the test phones before
# `shorebird patches set-track … --track stable` sends it to members.
#
# The patch targets the release whose version is in pubspec.yaml at <commit>.
# So keep `version:` UNCHANGED while patching a release; bump it only for the
# next full release.
set -euo pipefail

COMMIT="${1:?usage: patch.sh <commit> [--stable]}"
TRACK="staging"
[ "${2:-}" = "--stable" ] && TRACK="stable"
REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
KEY_PROPS="${H24_KEY_PROPERTIES:-$HOME/h24build/key.properties}"

command -v shorebird >/dev/null || { echo "shorebird CLI not found — see docs/shorebird.md §1"; exit 1; }
# Signing: the same upload key as every Help24 release. Either a key.properties
# (its storeFile must be an ABSOLUTE path, since it is copied into a temporary
# checkout) or the HELP24_KEYSTORE_* variables android/app/build.gradle reads.
if [ ! -f "$KEY_PROPS" ] && [ -z "${HELP24_KEYSTORE_PATH:-}" ]; then
  echo "No signing key: set H24_KEY_PROPERTIES to key.properties, or export HELP24_KEYSTORE_PATH/PASSWORD/ALIAS/KEY_PASSWORD"
  exit 1
fi

WORK="$(mktemp -d /tmp/h24-shorebird-patch-XXXX)"
trap 'git -C "$REPO" worktree remove --force "$WORK" >/dev/null 2>&1 || true' EXIT
git -C "$REPO" fetch --quiet origin
git -C "$REPO" worktree add --detach "$WORK" "$COMMIT" >/dev/null

cd "$WORK/mobile-app"
[ -f "$KEY_PROPS" ] && cp "$KEY_PROPS" android/key.properties
VERSION="$(grep -E '^version:' pubspec.yaml | awk '{print $2}')"
echo "Patching release $VERSION from $(git rev-parse --short HEAD) on the '$TRACK' track"

# Shorebird refuses or warns when the change is not patchable (native code,
# plugins with native parts, assets, Flutter version). Read its warnings: a
# warning about native changes means this needs a full release instead.
shorebird patch android --track="$TRACK"

APP_ID="$(grep -E '^app_id:' shorebird.yaml | awk '{print $2}')"
echo
if [ "$TRACK" = "staging" ]; then
  echo "Staged. Check it on a test phone (USB debugging on, adb sees it):"
  echo "  shorebird preview --track staging --app-id $APP_ID --release-version $VERSION"
  echo "Close the app fully and open it again — the patch applies on the next start."
  echo "Then send it to everyone:"
  echo "  shorebird patches set-track --release-version $VERSION --patch-number <n> --track stable"
else
  echo "Live for every device on $VERSION. Each device downloads it at its next start"
  echo "and runs it from the start after that."
fi
