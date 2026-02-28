#Requires -Version 5.1
<#
.SYNOPSIS
  Full cleanup of Gradle/Flutter Android build artifacts and optional release APK build.
.DESCRIPTION
  - Stops Java/Gradle daemons and processes
  - Removes corrupted Gradle wrapper downloads and caches (fixes "zip END header not found")
  - Clears Flutter and Android build outputs
  - Runs flutter clean, pub get, then (unless -CleanOnly) build apk --release
.PARAMETER CleanOnly
  If set, only run cleanup and flutter clean/pub get; do not build the APK.
.PARAMETER KeepGradleDist
  If set, do NOT delete Gradle wrapper dists (~/.gradle/wrapper/dists). Use when your network is unreliable so the next build can reuse an already-downloaded Gradle. Omit to fix "zip END header not found" (full clean).
.PARAMETER BuildRetries
  Number of times to retry the APK build on failure (e.g. Connection reset). Default 3.
.EXAMPLE
  .\scripts\clean_and_build_android.ps1
.EXAMPLE
  .\scripts\clean_and_build_android.ps1 -KeepGradleDist
.EXAMPLE
  .\scripts\clean_and_build_android.ps1 -CleanOnly
.NOTES
  Run from project root. Do not use gradlew --stop here (it triggers a Gradle download). For "39 packages have newer versions", run flutter pub outdated then optionally flutter pub upgrade.
#>
param([switch]$CleanOnly, [switch]$KeepGradleDist, [int]$BuildRetries = 3)

$ErrorActionPreference = "Stop"
# When run as .\scripts\clean_and_build_android.ps1 from repo root, PSScriptRoot = repo\scripts
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $ProjectRoot "pubspec.yaml"))) {
    $ProjectRoot = (Get-Location).Path
}
if (-not (Test-Path (Join-Path $ProjectRoot "pubspec.yaml"))) {
    Write-Error "Run this script from project root or from scripts folder. pubspec.yaml not found."
    exit 1
}

Set-Location $ProjectRoot
Write-Host "Project root: $ProjectRoot" -ForegroundColor Cyan

# ---- 1. Kill Java / Gradle processes (do NOT run gradlew --stop; it triggers Gradle download) ----
Write-Host "`n[1/6] Stopping Java/Gradle processes..." -ForegroundColor Yellow
Get-Process -Name "java" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name "gradle*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# ---- 2. Delete corrupted Gradle files and caches ----
Write-Host "`n[2/6] Removing Gradle caches" $(if ($KeepGradleDist) { "(keeping wrapper dists)" } else { "and wrapper distributions" }) "..." -ForegroundColor Yellow
$gradleUserHome = if ($env:GRADLE_USER_HOME) { $env:GRADLE_USER_HOME } else { Join-Path $env:USERPROFILE ".gradle" }

$dirsToRemove = @(
    (Join-Path $gradleUserHome "caches"),
    (Join-Path $gradleUserHome "daemon"),
    (Join-Path $gradleUserHome "native")
)
if (-not $KeepGradleDist) {
    $dirsToRemove = @( (Join-Path $gradleUserHome "wrapper\dists") ) + $dirsToRemove
}
foreach ($dir in $dirsToRemove) {
    if (Test-Path $dir) {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        Write-Host "  Removed: $dir"
    }
}

# ---- 3. Delete project build artifacts ----
Write-Host "`n[3/6] Removing project build artifacts..." -ForegroundColor Yellow
$projectDirs = @(
    (Join-Path $ProjectRoot "build"),
    (Join-Path $ProjectRoot "android\.gradle"),
    (Join-Path $ProjectRoot "android\build"),
    (Join-Path $ProjectRoot "android\app\build"),
    (Join-Path $ProjectRoot ".dart_tool"),
    (Join-Path $ProjectRoot ".flutter-plugins"),
    (Join-Path $ProjectRoot ".flutter-plugins-dependencies"),
    (Join-Path $ProjectRoot ".packages")
)
foreach ($dir in $projectDirs) {
    if (Test-Path $dir) {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        Write-Host "  Removed: $dir"
    }
}

# Remove ephemeral / generated files (Flutter)
$filesToRemove = @(
    (Join-Path $ProjectRoot "Generated.xcconfig"),
    (Join-Path $ProjectRoot "flutter_export_environment.sh")
)
foreach ($f in $filesToRemove) {
    if (Test-Path $f) {
        Remove-Item -Force $f -ErrorAction SilentlyContinue
        Write-Host "  Removed: $f"
    }
}
# Keep android\local.properties (Flutter SDK path); Flutter recreates it if missing.

# ---- 4. Flutter clean ----
Write-Host "`n[4/6] Running flutter clean..." -ForegroundColor Yellow
flutter clean

# ---- 5. Get dependencies ----
Write-Host "`n[5/6] Running flutter pub get..." -ForegroundColor Yellow
flutter pub get
if ($LASTEXITCODE -ne 0) { Write-Host "flutter pub get failed." -ForegroundColor Red; exit $LASTEXITCODE }

if ($CleanOnly) {
    Write-Host "`nClean only: skipping build. Run 'flutter build apk --release' when ready." -ForegroundColor Green
    exit 0
}

# ---- 6. Build release APK (with retries for Connection reset) ----
$attempt = 1
while ($true) {
    Write-Host "`n[6/6] Building release APK (attempt $attempt of $BuildRetries; may download Gradle and take several minutes)..." -ForegroundColor Yellow
    flutter build apk --release
    if ($LASTEXITCODE -eq 0) {
        $apkPath = Join-Path $ProjectRoot "build\app\outputs\flutter-apk\app-release.apk"
        Write-Host "`nBuild succeeded. APK: $apkPath" -ForegroundColor Green
        exit 0
    }
    if ($attempt -ge $BuildRetries) {
        Write-Host "`nBuild failed after $BuildRetries attempts (exit code $LASTEXITCODE)." -ForegroundColor Red
        Write-Host "If you see 'Connection reset', try: 1) Stable network, 2) .\scripts\clean_and_build_android.ps1 -KeepGradleDist (keeps Gradle cache), 3) Pre-cache: cd android; .\gradlew.bat --version; cd .." -ForegroundColor Yellow
        exit $LASTEXITCODE
    }
    Write-Host "Build failed (often network). Retrying in 10s..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    $attempt++
}
