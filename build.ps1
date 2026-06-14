# build.ps1
# Script to build the Twitch Streamlink GUI for release using the local portable Flutter SDK.

$ErrorActionPreference = "Stop"

$SdkDir = Join-Path $PSScriptRoot ".flutter-sdk"
$FlutterExe = Join-Path $SdkDir "flutter\bin\flutter.bat"

if (-not (Test-Path $FlutterExe)) {
    Write-Host "Local Flutter SDK not found! Please run .\setup.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Compiling Standalone Windows Executable..." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Using Local SDK: $FlutterExe" -ForegroundColor Gray
Write-Host "Compiling..." -ForegroundColor Yellow

try {
    & "$FlutterExe" build windows --release
    if ($LastExitCode -ne 0) {
        throw "Flutter compiler exited with code $LastExitCode"
    }
    
    $ReleaseFolder = Join-Path $PSScriptRoot "build\windows\x64\runner\Release"
    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host " Build Successful!" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host "Your standalone portable application folder is located at:" -ForegroundColor Gray
    Write-Host "  $ReleaseFolder" -ForegroundColor Cyan
    Write-Host "You can run 'streamlink_gui.exe' inside that folder directly." -ForegroundColor Yellow
} catch {
    Write-Host "`n[Error] Build failed: $_" -ForegroundColor Red
    Write-Host "[Troubleshoot] Ensure Visual Studio 2022 (with Desktop Development with C++ workload) is installed." -ForegroundColor Yellow
    Write-Host "[Troubleshoot] This build requires Windows Developer Mode to be enabled or running in an elevated shell." -ForegroundColor Yellow
    Write-Host "[Troubleshoot] Try running this build script in an elevated PowerShell (Run as Administrator) window." -ForegroundColor Green
    exit 1
}
