#!/usr/bin/env bash
# Shorebird RELEASE: a full APK that members install once, and that later
# Shorebird patches apply to. See docs/shorebird.md.
#
#   bash scripts/shorebird/release.sh <commit>
#
# Run in WSL, like the normal release build. Needs the Shorebird CLI logged in
# (`shorebird login`, once) and mobile-app/shorebird.yaml committed
# (`shorebird init`, once). Signing, the Gradle wrapper and pubspec.lock are
# handled by prepare.sh.
#
# H24_FLUTTER_VERSION must be the Flutter version the last normal release was
# built with. Shorebird builds with its own copy of exactly that version.
set -euo pipefail

COMMIT="${1:?usage: release.sh <commit>}"
FLUTTER_VERSION="${H24_FLUTTER_VERSION:?set H24_FLUTTER_VERSION to the Flutter version of the last release (flutter --version)}"
source "$(dirname "$0")/prepare.sh"
prepare_source "$COMMIT"

cd "$SRC"
echo "Releasing Help24 $VERSION from $COMMIT with Flutter $FLUTTER_VERSION"
shorebird release android --artifact apk --flutter-version="$FLUTTER_VERSION"

APK="build/app/outputs/flutter-apk/app-release.apk"
[ -f "$APK" ] || { echo "APK not found at $APK"; exit 1; }

# Patches to this release must build against the same dependencies.
mkdir -p "$LOCKS/$VERSION"
cp pubspec.lock "$LOCKS/$VERSION/pubspec.lock"

OUT="$H24/out/help24-$VERSION-shorebird.apk"
mkdir -p "$(dirname "$OUT")"
cp "$APK" "$OUT"
echo
echo "Release APK: $OUT"
echo "  size:   $(stat -c %s "$OUT") bytes"
echo "  sha256: $(sha256sum "$OUT" | awk '{print $1}')"
echo
echo "Next (docs/shorebird.md §3): check it on the test phones, publish it as the"
echo "GitHub release and on help24.co.ke (npm run sync:release in help24_website),"
echo "then raise ops.min_version to ${VERSION%%+*} so every member installs it once."
