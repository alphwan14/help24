# Android release build

## Quick fix: "zip END header not found" or corrupted Gradle

Run the full cleanup and build script from the **project root** (requires internet for first Gradle download):

```powershell
.\scripts\clean_and_build_android.ps1
```

This stops Java/Gradle processes, deletes corrupted wrapper downloads and caches, cleans the project, then builds the release APK (with up to 3 retries on network failure).

- **Connection reset during build?** Use `-KeepGradleDist` so the script does not delete the Gradle distribution; the next run can reuse it:  
  `.\scripts\clean_and_build_android.ps1 -KeepGradleDist`
- **Clean only (no build):** `.\scripts\clean_and_build_android.ps1 -CleanOnly`
- **Pre-cache Gradle** (when online) so a later full clean doesn’t re-download:  
  `cd android; .\gradlew.bat --version; cd ..`

---

## First run requires internet

The first time you run `flutter build apk --release`, the Gradle wrapper downloads the Gradle distribution (~150 MB) from `services.gradle.org`. If that download fails, the build fails.

### If you see network errors

- **`java.net.SocketException: Connection reset`** or **`java.net.UnknownHostException: services.gradle.org`**  
  The build failed because Gradle (or a dependency) could not be downloaded.

**Do this:**

1. **Check your network**  
   Make sure you have a stable internet connection and can open https://services.gradle.org in a browser.

2. **Pre-cache Gradle (recommended)**  
   When online, run once so Gradle is cached and future builds are more reliable:
   ```powershell
   cd android
   .\gradlew.bat --version
   cd ..
   ```
   Wait until it finishes (it may download Gradle). Then run:
   ```powershell
   flutter build apk --release
   ```

3. **Retry the build**  
   Often the failure is temporary. Run again:
   ```powershell
   flutter build apk --release
   ```

4. **If you use a proxy or VPN**  
   Configure Java/Gradle to use it, or try without VPN to rule out blocking.

5. **Corrupted cache**  
   If the download was interrupted, clear the wrapper cache and retry when online:
   ```powershell
   # Close IDE and any Gradle/Java processes first
   Remove-Item -Recurse -Force $env:USERPROFILE\.gradle\wrapper\dists\gradle-8.10.2-all -ErrorAction SilentlyContinue
   flutter build apk --release
   ```

## Build command

```powershell
flutter clean
flutter pub get
flutter build apk --release
```

The APK is generated at: `build/app/outputs/flutter-apk/app-release.apk`.

---

## Release signing

### Why a release build now fails without a key

`release` used to carry `signingConfig signingConfigs.debug`. That is not a
shortcut, it is a silent production failure. The debug key is generated
per-machine by the Android SDK and is **not** the certificate registered with the
identity provider, so a debug-signed release:

- fails Google Sign-In outright, and
- dies on phone OTP with a device-verification error,

while the build itself reports complete success. Nothing on the build machine
tells you the artifact is unshippable — you find out from users.

So `release` can no longer reach the debug key at all. With no signing material
the build **stops with an explicit message** instead of producing something that
looks fine. Debug builds are untouched and still need no keystore.

### One-time setup

**1. Create the keystore.** Keep the file and its passwords somewhere you will
still have them in five years — if you lose this key you can never publish an
update to the same listing again.

```powershell
keytool -genkeypair -v `
  -keystore $env:USERPROFILE\help24-release.jks `
  -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 `
  -alias help24
```

**2. Point the build at it.** Copy `android/key.properties.example` to
`android/key.properties` and fill in the four values:

```properties
storeFile=C:/Users/<you>/help24-release.jks
storePassword=<store password>
keyAlias=help24
keyPassword=<key password>
```

`key.properties`, `*.jks` and `*.keystore` are gitignored by both
`android/.gitignore` and the repo root `.gitignore`. Never commit them, never
paste them into a ticket, never echo them in a build log.

**3. Read the fingerprints:**

```powershell
keytool -list -v -keystore $env:USERPROFILE\help24-release.jks -alias help24
```

**4. Register them.** Add **both** SHA-1 and SHA-256 to the Firebase Android app,
then re-download `google-services.json`. Do this for every certificate that will
ever sign a build the users install:

| Certificate | Where it comes from | Needed because |
|---|---|---|
| Upload key | the keystore you just made | signs what you upload |
| Play App Signing key | Play Console → Setup → App signing | signs what users actually install |

Missing the Play App Signing certificate is the single most common cause of
"Google Sign-In works in my build but not from the Play Store".

### CI

Do not write a keystore into the workspace. Set these instead — the build reads
them when `key.properties` is absent:

| Variable | Value |
|---|---|
| `HELP24_KEYSTORE_PATH` | absolute path to the decoded `.jks` |
| `HELP24_KEYSTORE_PASSWORD` | store password |
| `HELP24_KEY_ALIAS` | key alias |
| `HELP24_KEY_PASSWORD` | key password |

Typically the runner decodes a base64 secret to a temp path and exports that
path. A variable that exists but is **empty** counts as missing — that is the
usual shape of a misconfigured secret, and it fails the build rather than
signing with the wrong key.

### Verifying which key signed an APK

```powershell
keytool -printcert -jarfile build\app\outputs\flutter-apk\app-release.apk
```

If the owner reads `CN=Android Debug, O=Android, C=US`, the artifact is
debug-signed and must not be shipped. After this change that cannot happen —
the build fails first — but the check is worth keeping in a release checklist.
