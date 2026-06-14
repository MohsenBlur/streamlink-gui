# setup.ps1
# Self-contained PowerShell script to set up a project-local Flutter SDK environment.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Configuration
$SdkDir = Join-Path $PSScriptRoot ".flutter-sdk"
$ZipPath = Join-Path $SdkDir "flutter.zip"
$FlutterExe = Join-Path $SdkDir "flutter\bin\flutter.bat"
$FlutterUrl = "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.44.2-stable.zip"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Setting up portable Twitch Streamlink GUI environment" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Ensure local SDK directory exists
if (-not (Test-Path $SdkDir)) {
    New-Item -ItemType Directory -Path $SdkDir | Out-Null
}

# 2. Check if Flutter is already installed locally
if (-not (Test-Path $FlutterExe)) {
    Write-Host "Portable Flutter SDK not found. Starting download (approx. 700MB)..." -ForegroundColor Yellow
    Write-Host "Downloading via curl.exe from: $FlutterUrl" -ForegroundColor Gray
    
    # Use curl.exe directly with progress bar
    try {
        & curl.exe -L -o "$ZipPath" "$FlutterUrl"
        Write-Host "Download complete. Extracting files..." -ForegroundColor Green
    } catch {
        Write-Host "curl.exe failed, falling back to WebClient..." -ForegroundColor Yellow
        $WebClient = New-Object System.Net.WebClient
        $WebClient.DownloadFile($FlutterUrl, $ZipPath)
        Write-Host "Download complete. Extracting files..." -ForegroundColor Green
    }
    
    # Extract using 7z
    Write-Host "Unpacking using 7-Zip..." -ForegroundColor Yellow
    & 7z x "$ZipPath" -o"$SdkDir" -y | Out-Null
    
    # Clean up zip
    if (Test-Path $ZipPath) {
        Remove-Item $ZipPath -Force
    }
    Write-Host "Extraction complete!" -ForegroundColor Green
} else {
    Write-Host "Local Flutter SDK already exists. Skipping download." -ForegroundColor Green
}

# Verify flutter bat is present
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
