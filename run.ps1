# run.ps1
# Script to run the Twitch Streamlink GUI using the local portable Flutter SDK.

$ErrorActionPreference = "Stop"

$SdkDir = Join-Path $PSScriptRoot ".flutter-sdk"
$FlutterExe = Join-Path $SdkDir "flutter\bin\flutter.bat"

if (-not (Test-Path $FlutterExe)) {
    Write-Host "Local Flutter SDK not found! Please run .\setup.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Launching Twitch Streamlink GUI..." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Using Local SDK: $FlutterExe" -ForegroundColor Gray
Write-Host "Please wait, launching Windows desktop build..." -ForegroundColor Yellow

try {
    & "$FlutterExe" run -d windows
    if ($LastExitCode -ne 0) {
        throw "Flutter run command exited with code $LastExitCode"
    }
} catch {
    Write-Host "`n[Error] Failed to run the application: $_" -ForegroundColor Red
    Write-Host "[Troubleshoot] This is usually caused by Developer Mode being disabled on Windows." -ForegroundColor Yellow
    Write-Host "[Troubleshoot] To solve this, run PowerShell/Terminal as Administrator and run .\run.ps1 again, or enable Developer Mode in Windows Settings." -ForegroundColor Green
    exit 1
}
