param(
    [string]$Python = 'python',
    [switch]$BuildAndroidDebug
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutter = Join-Path $projectRoot '.tools/flutter/bin/flutter.bat'
$dart = Join-Path $projectRoot '.tools/flutter/bin/cache/dart-sdk/bin/dart.exe'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:CI = 'true'
Push-Location $projectRoot
try {
    & $Python -m ruff check scripts tests integration_tests
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & $Python -m unittest discover -s tests -v
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Push-Location mobile
    try {
        & $dart run tool/generate_translations.dart --check
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        & $flutter analyze --no-pub
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        # Keep test workers sequential on Windows. Parallel local
        # runs left different suites incomplete; retain every test and assertion.
        & $flutter test --no-pub --concurrency=1
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        & $dart run tool/storage_crash_probe.dart
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Push-Location packages/care_ort
        try {
            & $dart analyze
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } finally { Pop-Location }
        if ($BuildAndroidDebug) {
            & $flutter build apk --debug --target-platform=android-arm64
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            Push-Location android
            try {
                & ./gradlew.bat :app:prepareReleaseAudit '-Ptarget-platform=android-arm64'
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                & ./gradlew.bat :ad-test:assembleDebug '-PcareDeviceTest=ads'
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            } finally { Pop-Location }
            & "$PSScriptRoot/check_android_ad_isolation.ps1" `
                -AdApk build/ad-test/outputs/apk/debug/ad-test-debug.apk `
                -NotebookApk build/app/outputs/flutter-apk/app-debug.apk
        }
    } finally { Pop-Location }
    if ($BuildAndroidDebug) {
        & $Python -m scripts.audit_mobile_release --android-only --android-release-dir mobile/build/app/reports/release-audit
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
} finally { Pop-Location }
