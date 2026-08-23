# setup.ps1
# Self-contained PowerShell script to set up a project-local Flutter SDK environment.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Configuration
#
# The SDK version and its published SHA-256 live in tools/flutter-sdk.json, the
# single source of truth shared with the CI and release workflows. Pinning the
# version in three places meant a CI bump left every local build on the old SDK
# - and "it analyzes clean here" stopped meaning anything.
$SdkDir = Join-Path $PSScriptRoot ".flutter-sdk"
$ZipPath = Join-Path $SdkDir "flutter.zip"
$FlutterExe = Join-Path $SdkDir "flutter\bin\flutter.bat"

$SdkManifestPath = Join-Path $PSScriptRoot "tools\flutter-sdk.json"
if (-not (Test-Path $SdkManifestPath)) {
    Write-Error "Missing $SdkManifestPath - it pins the Flutter SDK version and hash."
}
$SdkManifest = Get-Content $SdkManifestPath -Raw | ConvertFrom-Json
$FlutterVersion = $SdkManifest.version
$FlutterSha256 = $SdkManifest.sha256.ToLowerInvariant()
$FlutterUrl = "https://storage.googleapis.com/flutter_infra_release/releases/$($SdkManifest.archive)"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Setting up portable Twitch Streamlink GUI environment" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Flutter SDK: $FlutterVersion ($($SdkManifest.channel))" -ForegroundColor Gray

# 1. Ensure local SDK directory exists
if (-not (Test-Path $SdkDir)) {
    New-Item -ItemType Directory -Path $SdkDir | Out-Null
}

# 2. Check if Flutter is already installed locally
if (-not (Test-Path $FlutterExe)) {
    Write-Host "Portable Flutter SDK not found. Starting download (approx. 700MB)..." -ForegroundColor Yellow
    Write-Host "Downloading via curl.exe from: $FlutterUrl" -ForegroundColor Gray

    # A native exe that fails does NOT throw, so the old try/catch here could
    # not catch a failed curl: a 404, a proxy error page or a connection
    # dropped at 90% all fell straight through to extraction. Check the exit
    # code and the file, and only then fall back.
    $downloaded = $false
    try {
        & curl.exe -fL --retry 3 -o "$ZipPath" "$FlutterUrl"
        $downloaded = ($LASTEXITCODE -eq 0) -and (Test-Path $ZipPath)
        if (-not $downloaded) {
            Write-Host "curl.exe exited with code $LASTEXITCODE." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "curl.exe could not be run: $_" -ForegroundColor Yellow
    }

    if (-not $downloaded) {
        Write-Host "Falling back to WebClient..." -ForegroundColor Yellow
        if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
        $WebClient = New-Object System.Net.WebClient
        $WebClient.DownloadFile($FlutterUrl, $ZipPath)
    }

    if (-not (Test-Path $ZipPath)) {
        Write-Error "Download produced no file at $ZipPath."
    }

    # Verify before extracting. ~700 MB over a link that may be proxied or
    # intercepted, expanded into the toolchain that compiles this app, is not
    # something to take on trust - tools/fetch-deps.ps1 verifies every one of
    # its far smaller downloads.
    Write-Host "Verifying download..." -ForegroundColor Yellow
    $actualSha = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha -ne $FlutterSha256) {
        Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
        Write-Error @"
SHA-256 mismatch for the Flutter SDK archive.
  expected: $FlutterSha256
  actual:   $actualSha
The download was corrupted or intercepted. If Google legitimately republished
$FlutterVersion, update tools/flutter-sdk.json deliberately - do not paste the
new hash without checking what changed.
"@
    }
    Write-Host "Verified (SHA-256 matches tools/flutter-sdk.json)." -ForegroundColor Green

    # Extract. 7-Zip is much faster on an archive this size but is not part of
    # a stock Windows; the old script assumed it, so a machine without it got
    # an empty .flutter-sdk and a cheerful "Extraction complete!".
    $SevenZip = (Get-Command 7z -ErrorAction SilentlyContinue)
    if ($SevenZip) {
        Write-Host "Unpacking using 7-Zip..." -ForegroundColor Yellow
        & 7z x "$ZipPath" -o"$SdkDir" -y | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "7z exited with code $LASTEXITCODE while extracting the SDK."
        }
    } else {
        Write-Host "7-Zip not found; unpacking with Expand-Archive (slower)..." -ForegroundColor Yellow
        Expand-Archive -Path $ZipPath -DestinationPath $SdkDir -Force
    }

    # Clean up zip
    if (Test-Path $ZipPath) {
        Remove-Item $ZipPath -Force
    }
    Write-Host "Extraction complete!" -ForegroundColor Green
} else {
    Write-Host "Local Flutter SDK already exists. Skipping download." -ForegroundColor Green
}

# Verify flutter bat is present.
# Write-Error terminates here because $ErrorActionPreference is "Stop".
if (-not (Test-Path $FlutterExe)) {
    Write-Error "Flutter executable could not be found after extraction at $FlutterExe."
}

# 3. Configure local Flutter
Write-Host "Configuring local Flutter..." -ForegroundColor Yellow
& "$FlutterExe" config --no-analytics | Out-Null
& "$FlutterExe" config --enable-windows-desktop | Out-Null
Write-Host "Local Flutter configured successfully." -ForegroundColor Green

# 4. Initialize Flutter project if not already initialized
if (-not (Test-Path (Join-Path $PSScriptRoot "pubspec.yaml"))) {
    Write-Host "Initializing new Flutter Windows project..." -ForegroundColor Yellow
    & "$FlutterExe" create --platforms=windows --org com.streamlinkgui --project-name streamlink_gui .
    Write-Host "Flutter project initialized." -ForegroundColor Green
} else {
    Write-Host "Project already initialized (pubspec.yaml exists)." -ForegroundColor Green
}

# 5. Run flutter doctor
Write-Host "Running flutter doctor..." -ForegroundColor Yellow
& "$FlutterExe" doctor

Write-Host "`nSetup complete! You can now run the app using .\run.ps1" -ForegroundColor Green
