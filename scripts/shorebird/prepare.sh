# Shared setup for release.sh and patch.sh. Sourced, not run.
#
# After `prepare_source <commit>`:
#   $SRC      a clean copy of mobile-app at <commit> (git archive, so the
#             Windows repo's worktree list is never touched)
#   $VERSION  pubspec.yaml's version at <commit>
#   signing   HELP24_KEYSTORE_* exported (values never printed), or the
#             key.properties named by H24_KEY_PROPERTIES copied in
#
# The inputs git does not track come from the Windows working tree, as in
# ~/h24build/scripts/build-release.sh: the Gradle wrapper, and pubspec.lock.
# A patch must be built against the dependencies its release was built with,
# so release.sh keeps the release's resolved lock in $LOCKS/<version> and
# patch.sh uses it.

REPO="$(git -c safe.directory='*' -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
WIN_APP="$REPO/mobile-app"
H24="$HOME/h24build"
LOCKS="$H24/shorebird/locks"

# The WSL build toolchain, when present (docs: wsl-release-build).
if [ -d "$H24/opt/jdk17" ]; then
  export JAVA_HOME="$H24/opt/jdk17" ANDROID_HOME="$H24/opt/android-sdk" ANDROID_SDK_ROOT="$H24/opt/android-sdk"
  export PATH="$H24/opt/unzip/usr/bin:$H24/opt/jdk17/bin:$PATH"
fi
export PATH="$HOME/.shorebird/bin:$PATH"

prepare_source() {
  local commit="$1"
  command -v shorebird >/dev/null || { echo "shorebird CLI not found (docs/shorebird.md §1)"; exit 1; }

  SRC="$H24/sb-src-$commit"
  rm -rf "$SRC"; mkdir -p "$SRC"
  git -c safe.directory='*' -C "$REPO" archive "$commit" mobile-app | tar -x -C "$SRC"
  SRC="$SRC/mobile-app"
  [ -f "$SRC/shorebird.yaml" ] || { echo "mobile-app/shorebird.yaml is missing at $commit. Run 'shorebird init' and commit it first."; exit 1; }
  VERSION="$(grep -E '^version:' "$SRC/pubspec.yaml" | awk '{print $2}')"

  cp "$WIN_APP/android/gradlew" "$SRC/android/gradlew"
  cp "$WIN_APP/android/gradle/wrapper/gradle-wrapper.jar" "$SRC/android/gradle/wrapper/gradle-wrapper.jar"
  chmod +x "$SRC/android/gradlew"

  if [ -f "$LOCKS/$VERSION/pubspec.lock" ]; then
    cp "$LOCKS/$VERSION/pubspec.lock" "$SRC/pubspec.lock"
    echo "pubspec.lock: the one release $VERSION was built with"
  else
    cp "$WIN_APP/pubspec.lock" "$SRC/pubspec.lock"
    echo "pubspec.lock: from the Windows working tree"
  fi

  # Signing: the upload key every Help24 release uses.
  if [ -n "${H24_KEY_PROPERTIES:-}" ]; then
    [ -f "$H24_KEY_PROPERTIES" ] || { echo "H24_KEY_PROPERTIES does not exist: $H24_KEY_PROPERTIES"; exit 1; }
    cp "$H24_KEY_PROPERTIES" "$SRC/android/key.properties"
    echo "signing: $H24_KEY_PROPERTIES"
  elif [ -z "${HELP24_KEYSTORE_PATH:-}" ]; then
    local kp="$WIN_APP/android/key.properties"
    [ -f "$kp" ] || { echo "No signing key: set H24_KEY_PROPERTIES or HELP24_KEYSTORE_*"; exit 1; }
    getp() { grep -E "^$1=" "$kp" | head -1 | cut -d= -f2- | tr -d '\r'; }
    local store; store="$(getp storeFile)"
    # C:/Users/... or C:\Users\... -> /mnt/c/Users/...
    store="$(printf '%s' "$store" | sed -E 's#\\#/#g; s#^([A-Za-z]):/#/mnt/\L\1/#')"
    export HELP24_KEYSTORE_PATH="$store"
    export HELP24_KEYSTORE_PASSWORD="$(getp storePassword)"
    export HELP24_KEY_ALIAS="$(getp keyAlias)"
    export HELP24_KEY_PASSWORD="$(getp keyPassword)"
    for v in HELP24_KEYSTORE_PASSWORD HELP24_KEY_ALIAS HELP24_KEY_PASSWORD; do
      [ -n "${!v}" ] || { echo "signing: $v missing from $kp"; exit 1; }
    done
    [ -r "$HELP24_KEYSTORE_PATH" ] || { echo "signing: keystore not readable at $HELP24_KEYSTORE_PATH"; exit 1; }
    echo "signing: Windows key.properties (values not printed)"
  fi
}
