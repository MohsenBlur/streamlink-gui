<#
.SYNOPSIS
  Captures the screenshot matrix for one build into shots/<Phase>/.

.DESCRIPTION
  Launches the app ONCE and resizes between captures, rather than relaunching
  per size - a relaunch costs several seconds and re-triggers first-run work.

  Config is isolated: a portable.txt marker beside the exe makes the app read
  and write beside itself, and a copy of the real channels_config.json is
  staged there. The user's live settings and OAuth token are never written to.

  Build with -dart-define=APP_VERSION=99.0.0 so the updater never offers an
  update; the modal sits over the middle of every screen otherwise.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Phase,
    [string]$Exe = 'build\windows\x64\runner\Release\streamlink_gui.exe',
    [ValidateSet('dark', 'light', 'both')][string]$Theme = 'both',
    [string]$Accent,
    [switch]$KeepOpen
)

# A Debug build is NOT a substitute for a Release one when reviewing the UI.
#
# v1.7.0 shipped a settings dialog whose entire body was a grey error box in
# release, while every debug screenshot of it looked correct. The cause was a
# Flexible inside a Wrap: Flutter detects that misplaced ParentDataWidget inside
# an assert, so DEBUG logs it, declines to apply the parent data and renders on,
# while RELEASE strips the check, throws on the cast, and swaps in a
# RenderErrorBox. Debug is structurally incapable of showing that class of bug.
function Assert-ReleaseBuild([string]$exePath) {
    if ($exePath -and $exePath.ToLower().Contains('\debug\')) {
        Write-Warning ("DEBUG BUILD WARNING: capturing '$exePath'. Debug masks " +
            "misplaced ParentDataWidgets and other assert-guarded faults that " +
            "only throw in release. Shoot the Release build before believing a " +
            "screenshot.")
    }
}

$ErrorActionPreference = 'Stop'

# w, h, label. Both sides of the 1180 boundary: a one-pixel difference must not
# look like a redesign.
$SIZES = @(
    @{ w = 380;  h = 500;  label = '380x500' }     # enforced minimum
    @{ w = 700;  h = 800;  label = '700x800' }     # portrait -> horizontal bar
    @{ w = 900;  h = 600;  label = '900x600' }
    @{ w = 1179; h = 720;  label = '1179x720' }
    @{ w = 1181; h = 720;  label = '1181x720' }
    @{ w = 1600; h = 1000; label = '1600x1000' }
)

Assert-ReleaseBuild $Exe

$repo = Split-Path -Parent $PSScriptRoot
$relDir = Split-Path -Parent (Join-Path $repo $Exe)
$cfgPath = Join-Path $relDir 'channels_config.json'
$srcCfg = Join-Path $env:APPDATA 'TwitchStreamlinkGUI\channels_config.json'

function Stop-App {
    Get-Process streamlink_gui -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Kill(); $_.WaitForExit(5000) }
    Start-Sleep -Milliseconds 600
}

function Set-IsolatedConfig([bool]$dark, [string]$accentHex) {
    if (-not (Test-Path $cfgPath)) { Copy-Item $srcCfg $cfgPath -Force }
    $json = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $json.settings.is_dark_theme = $dark
    if ($accentHex) {
        if ($dark) { $json.settings.dark_accent_color_hex = $accentHex }
        else { $json.settings.light_accent_color_hex = $accentHex }
    }
    # The window opens at its stored size; start wide so the first capture is
    # not fighting a 380px restore.
    $json.settings.is_window_maximized = $false
    $json.settings.window_width = 1600
    $json.settings.window_height = 1000
    $json | ConvertTo-Json -Depth 64 | Set-Content $cfgPath -Encoding utf8
}

New-Item -ItemType Directory -Path (Join-Path $repo "shots\$Phase") -Force | Out-Null
if (-not (Test-Path (Join-Path $relDir 'portable.txt'))) {
    New-Item -ItemType File -Path (Join-Path $relDir 'portable.txt') | Out-Null
}

$themes = if ($Theme -eq 'both') { @($true, $false) } else { @($Theme -eq 'dark') }

foreach ($dark in $themes) {
    $themeName = if ($dark) { 'dark' } else { 'light' }
    $suffix = if ($Accent) { "_$themeName`_accent" } else { "_$themeName" }

    Stop-App
    Set-IsolatedConfig -dark $dark -accentHex $Accent

    Write-Host "=== $themeName$(if ($Accent) { " (accent $Accent)" }) ===" -ForegroundColor Cyan

    $first = $true
    foreach ($s in $SIZES) {
        $out = "shots/$Phase/home_$($s.label)$suffix.png"
        $args = @{
            Out      = $out
            Width    = $s.w
            Height   = $s.h
            SettleMs = 1200
        }
        if ($first) {
            $args.LaunchExe = $Exe
            $args.SettleMs = 3500     # first frame + channel load
            $first = $false
        }
        & (Join-Path $PSScriptRoot 'shoot.ps1') @args
    }

    # Other screens, reached by clicking. Home alone is NOT enough coverage:
    # a crash in the channel dashboard survived seven phases of this matrix
    # because every capture showed the welcome screen, which never builds it.
    # A hashtable must be SPLATTED with @name; passing @{...} inline hands the
    # script one positional argument instead of named parameters.
    $channelArgs = @{
        Out      = "shots/$Phase/channel_1600x1000$suffix.png"
        Width    = 1600
        Height   = 1000
        SettleMs = 3500
        ClickAt  = '120,400'         # first channel row in the sidebar
    }
    & (Join-Path $PSScriptRoot 'shoot.ps1') @channelArgs

    $libraryArgs = @{
        Out      = "shots/$Phase/library_1600x1000$suffix.png"
        NoResize = $true
        SettleMs = 2500
        ClickAt  = '100,960'         # Library button (the gear is at ~44)
    }
    & (Join-Path $PSScriptRoot 'shoot.ps1') @libraryArgs
}

if (-not $KeepOpen) { Stop-App }
Write-Host "Matrix complete: shots/$Phase" -ForegroundColor Green
