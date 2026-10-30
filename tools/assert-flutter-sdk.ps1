<#
.SYNOPSIS
  Fails unless the project-local Flutter SDK is the version tools/flutter-sdk.json pins.

.DESCRIPTION
  setup.ps1 skips the download whenever .flutter-sdk already exists, so bumping
  the pin moved CI to the new SDK while every local build stayed on the old
  one. pub get then re-resolved the SDK-pinned packages (meta, test_api) and
  left pubspec.lock dirty - a lock CI's --enforce-lockfile now rejects - and a
  local build ran on a different engine from the release. Present is not
  enough; it must be the pinned version.

  Exits 0 on a match and 1 otherwise, so callers test $LastExitCode exactly as
  they do for verify-bundle.ps1.

.EXAMPLE
  & tools\assert-flutter-sdk.ps1 -SdkRoot .flutter-sdk\flutter
  if ($LastExitCode -ne 0) { exit 1 }
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$SdkRoot)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$pinned = (Get-Content (Join-Path $repo 'tools\flutter-sdk.json') -Raw | ConvertFrom-Json).version

# The flutter tool writes this on its first run, so a freshly unpacked SDK may
# not have it yet; one run of the tool creates it.
$versionFile = Join-Path $SdkRoot 'bin\cache\flutter.version.json'
$flutterBat = Join-Path $SdkRoot 'bin\flutter.bat'
if (-not (Test-Path $versionFile) -and (Test-Path $flutterBat)) {
    & $flutterBat --version | Out-Null
}
if (-not (Test-Path $versionFile)) {
    Write-Host "Cannot tell which Flutter SDK is at $SdkRoot ($versionFile is missing)." -ForegroundColor Red
    Write-Host "Delete .flutter-sdk and run .\setup.ps1 to install the pinned SDK ($pinned)." -ForegroundColor Yellow
    exit 1
}

$info = Get-Content $versionFile -Raw | ConvertFrom-Json
$installed = if ($info.frameworkVersion) { $info.frameworkVersion } else { $info.flutterVersion }
if ($installed -ne $pinned) {
    Write-Host "The local Flutter SDK is $installed, but tools/flutter-sdk.json pins $pinned." -ForegroundColor Red
    Write-Host "Delete .flutter-sdk and run .\setup.ps1 to install the pinned SDK." -ForegroundColor Yellow
    exit 1
}
exit 0
