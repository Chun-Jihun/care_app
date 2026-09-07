param(
    [ValidateSet('SetupAndroid','Dependencies','Analyze','Test','BuildAndroid','Run')]
    [string]$Action = 'Test'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolRoot = Join-Path $projectRoot '.tools'
$flutterCommand = Join-Path $toolRoot 'flutter\bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutterCommand)) { throw 'Install Flutter into .tools/flutter or open mobile/ using your Flutter SDK.' }
$env:PUB_CACHE = Join-Path $toolRoot 'pub-cache'
$env:GRADLE_USER_HOME = Join-Path $toolRoot 'gradle-cache'
$env:ANDROID_HOME = Join-Path $toolRoot 'android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:CI = 'true'
$java21 = 'C:\Program Files\Java\jdk-21'
if (Test-Path -LiteralPath $java21) { $env:JAVA_HOME = $java21 }
if ($Action -eq 'SetupAndroid') {
    $archive = Join-Path $toolRoot 'android-commandline-tools.zip'
    $sdkManager = Join-Path $env:ANDROID_HOME 'cmdline-tools\bin\sdkmanager.bat'
    New-Item -ItemType Directory -Path $env:ANDROID_HOME -Force | Out-Null
    if (-not (Test-Path -LiteralPath $sdkManager)) {
        Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip' -OutFile $archive
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne '90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a') { throw 'Android SDK archive checksum mismatch.' }
        Expand-Archive -LiteralPath $archive -DestinationPath $env:ANDROID_HOME
    }
    1..100 | ForEach-Object { 'y' } | & $sdkManager "--sdk_root=$env:ANDROID_HOME" --licenses | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Android SDK license setup failed.' }
    & $sdkManager "--sdk_root=$env:ANDROID_HOME" 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0'
    if ($LASTEXITCODE -ne 0) { throw 'Android SDK setup failed.' }
    exit 0
}
Push-Location (Join-Path $projectRoot 'mobile')
try {
    switch ($Action) {
        'Dependencies' { & $flutterCommand pub get }
        'Analyze' { & $flutterCommand analyze }
        'Test' { & $flutterCommand test }
        'BuildAndroid' { & $flutterCommand build apk --release }
        'Run' { & $flutterCommand run }
    }
    $resultCode = $LASTEXITCODE
} finally { Pop-Location }
exit $resultCode
