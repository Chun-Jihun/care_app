param(
    [Parameter(Mandatory)][string]$AdApk,
    [string]$NotebookApk
)
$ErrorActionPreference = 'Stop'
$aapt = Join-Path $env:ANDROID_HOME 'build-tools/36.0.0/aapt.exe'
$adInfo = (& $aapt dump badging $AdApk) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the ad test APK.' }
if ($adInfo -notmatch "(?m)^package: name='org\.carenotebook\.care_notebook\.adtest' " -or
    $adInfo -notmatch "(?m)^launchable-activity: name='org\.carenotebook\.care_notebook\.adtest\.PublicHelpTestActivity' ") {
    throw 'The ad test must launch public help from its own application ID.'
}
if ($adInfo -match "uses-permission[^:]*: name='[^']*(RECORD_AUDIO|CAMERA|READ_MEDIA|EXTERNAL_STORAGE|USE_BIOMETRIC|POST_NOTIFICATIONS|AD_ID)") {
    throw 'The ad test APK requests a sensitive permission.'
}
$adManifest = & $aapt dump xmltree $AdApk AndroidManifest.xml
if ($LASTEXITCODE -ne 0 -or $adManifest -match 'sharedUserId|flutterEmbedding|\.MainActivity|DailyWidgetProvider|MobileAdsInitProvider') {
    throw 'The ad test APK contains a shared UID, notebook component, or automatic ads initializer.'
}
$adFiles = & $aapt list $AdApk
if ($LASTEXITCODE -ne 0 -or $adFiles -match '^assets/flutter_assets/|/libflutter\.so$') {
    throw 'The ad test APK contains the Flutter notebook runtime.'
}
if ($NotebookApk) {
    $notebookManifest = & $aapt dump xmltree $NotebookApk AndroidManifest.xml
    if ($LASTEXITCODE -ne 0 -or $notebookManifest -match 'com\.google\.android\.gms\.ads|PublicHelpTestActivity') {
        throw 'The notebook APK contains an ads component.'
    }
}
Write-Output 'Android ad test APK isolation verified.'
