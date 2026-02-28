param(
    [switch]$AutoFix = $true
)

Write-Host "=======================================" -ForegroundColor Cyan
Write-Host "    FIX GRADLE AND BUILD APK" -ForegroundColor Cyan
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host ""

$projectPath = "C:\Users\user\Desktop\Projects\help24"
Set-Location $projectPath

Write-Host "[1/7] Killing any Java/Gradle processes..." -ForegroundColor Yellow
Get-Process -Name "java", "gradle*", "gradlew*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host "  ✓ Processes stopped" -ForegroundColor Green

Write-Host "[2/7] Fixing gradle-wrapper.properties..." -ForegroundColor Yellow
$wrapperFile = "android\gradle\wrapper\gradle-wrapper.properties"
if (Test-Path $wrapperFile) {
    # Backup original
    Copy-Item $wrapperFile "$wrapperFile.backup" -Force
    
    # Update to Gradle 8.11.1
    $content = Get-Content $wrapperFile
    $newContent = $content -replace 'gradle-[\d.]+-all\.zip', 'gradle-8.11.1-all.zip'
    $newContent = $newContent -replace 'distributionUrl=.*', 'distributionUrl=https\://services.gradle.org/distributions/gradle-8.11.1-all.zip'
    $newContent | Set-Content $wrapperFile
    Write-Host "  ✓ Updated to Gradle 8.11.1" -ForegroundColor Green
} else {
    Write-Host "  ✗ gradle-wrapper.properties not found!" -ForegroundColor Red
    exit 1
}

Write-Host "[3/7] Fixing android/build.gradle..." -ForegroundColor Yellow
$buildGradle = "android\build.gradle"
if (Test-Path $buildGradle) {
    $content = Get-Content $buildGradle
    
    # Update Android Gradle plugin version if needed
    if ($content -match 'com.android.tools.build:gradle:[\d.]+') {
        $newContent = $content -replace 'com.android.tools.build:gradle:[\d.]+', 'com.android.tools.build:gradle:8.4.0'
        $newContent | Set-Content $buildGradle
        Write-Host "  ✓ Updated Android Gradle plugin" -ForegroundColor Green
    }
} else {
    Write-Host "  ✗ android/build.gradle not found!" -ForegroundColor Red
}

Write-Host "[4/7] Fixing android/app/build.gradle..." -ForegroundColor Yellow
$appBuildGradle = "android\app\build.gradle"
if (Test-Path $appBuildGradle) {
    # Ensure compileSdk is set to 34
    $content = Get-Content $appBuildGradle
    if ($content -notmatch 'compileSdk 34' -and $content -notmatch 'compileSdkVersion 34') {
        Write-Host "  ⚠ Consider updating compileSdk to 34 in $appBuildGradle" -ForegroundColor Yellow
    }
} else {
    Write-Host "  ✗ android/app/build.gradle not found!" -ForegroundColor Red
}

Write-Host "[5/7] Clearing corrupted Gradle cache..." -ForegroundColor Yellow
$gradleDists = "$env:USERPROFILE\.gradle\wrapper\dists"
if (Test-Path $gradleDists) {
    Remove-Item -Path "$gradleDists\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  ✓ Gradle cache cleared" -ForegroundColor Green
}

Write-Host "[6/7] Cleaning Flutter project..." -ForegroundColor Yellow
flutter clean
Remove-Item -Path ".dart_tool" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "build" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  ✓ Flutter project cleaned" -ForegroundColor Green

Write-Host "[7/7] Getting dependencies and building APK..." -ForegroundColor Yellow
Write-Host ""
Write-Host "---------------------------------------" -ForegroundColor Gray
Write-Host "STEP 1: flutter pub get" -ForegroundColor White
flutter pub get

Write-Host ""
Write-Host "STEP 2: Pre-caching Gradle" -ForegroundColor White
Push-Location android
.\gradlew.bat --version
Pop-Location

Write-Host ""
Write-Host "STEP 3: Building APK" -ForegroundColor White
Write-Host "This may take 5-10 minutes..." -ForegroundColor Yellow
flutter build apk --release --verbose

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "=======================================" -ForegroundColor Green
    Write-Host "✅ BUILD SUCCESSFUL!" -ForegroundColor Green
    Write-Host "=======================================" -ForegroundColor Green
    Write-Host "APK location: build\app\outputs\flutter-apk\app-release.apk" -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "=======================================" -ForegroundColor Red
    Write-Host "❌ BUILD FAILED!" -ForegroundColor Red
    Write-Host "=======================================" -ForegroundColor Red
    Write-Host "Running diagnostics..." -ForegroundColor Yellow
    
    # Diagnostic info
    Write-Host ""
    Write-Host "Current Gradle version in properties:" -ForegroundColor Cyan
    Get-Content "android\gradle\wrapper\gradle-wrapper.properties" | Select-String "distributionUrl"
    
    Write-Host ""
    Write-Host "Android Gradle plugin version:" -ForegroundColor Cyan
    Select-String -Path "android\build.gradle" -Pattern "com.android.tools.build:gradle" -ErrorAction SilentlyContinue
    
    Write-Host ""
    Write-Host "Try manual fix:" -ForegroundColor Yellow
    Write-Host "1. cd android" -ForegroundColor White
    Write-Host "2. .\gradlew.bat clean" -ForegroundColor White
    Write-Host "3. .\gradlew.bat --refresh-dependencies" -ForegroundColor White
    Write-Host "4. cd .." -ForegroundColor White
    Write-Host "5. flutter build apk --release" -ForegroundColor White
}