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
