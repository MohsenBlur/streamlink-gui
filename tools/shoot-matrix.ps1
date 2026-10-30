<#
.SYNOPSIS
  Captures the screenshot matrix for one build into shots/<Phase>/.

.DESCRIPTION
  Launches the app ONCE and resizes between captures, rather than relaunching
  per size - a relaunch costs several seconds and re-triggers first-run work.

  Config is isolated: a portable.txt marker beside the exe makes the app read
  and write beside itself, and a copy of the real channels_config.json, its
  tokens blanked, is staged there: the build runs signed out, so the channel
  screen shows no VOD list. The user's live settings and OAuth token are
  never written to, nor copied.
  Only the build under test is stopped and captured. Running portable, it is
  its own single-instance scope, so an installed copy resting in the tray no
  longer blocks the launch; another copy from the same folder still makes it
  refuse rather than shoot (see shoot.ps1).

  Build with -dart-define=APP_VERSION=99.0.0 so the updater never offers an
  update; the modal sits over the middle of every screen otherwise.

  -Position puts the window somewhere of your choosing - a monitor you are
  not working on - from the launch on: the staged config opens it there, and
  every capture moves it back there before sizing. Without it the window
  opens where the copied config says, which is wherever the real app last
  was. Captures never bring the window to the foreground unless -Focus is
  passed, and the two clicks into the channel and Library screens are
  posted to the app's view (shoot.ps1 -ClickAt), so they do not activate it
  either. A -Position from which any size in the matrix would reach onto
  a second monitor is refused before anything launches.

  Nor does the launch's show: the build is started with SW_SHOWNOACTIVATE
  (shoot.ps1 -NoActivate), so neither its start nor its first show takes
  the foreground from the user's window. -NormalLaunch starts it as a user
  would instead.

.EXAMPLE
  # A second monitor left of the primary, 2160 physical px wide at 150%. The
  # widest size, 1600 logical, is 2400 physical there: starting 240px past
  # the desktop's left edge lets the overhang fall off the desktop instead
  # of onto the primary.
  ./tools/shoot-matrix.ps1 -Phase review -Position '-2400,-813'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Phase,
    [string]$Exe = 'build\windows\x64\runner\Release\streamlink_gui.exe',
    [ValidateSet('dark', 'light', 'both')][string]$Theme = 'both',
    [string]$Accent,
    [switch]$KeepOpen,
    # "x,y", physical virtual-desktop pixels: where the window opens and is
    # shot (see .DESCRIPTION). Each size grows right and down from here; one
    # that would reach onto another monitor is refused (see the example).
    [string]$Position,
    # Bring the window to the foreground for each capture (shoot.ps1 -Focus).
    [switch]$Focus,
    # Launch with a normal, activating show rather than SW_SHOWNOACTIVATE.
    [switch]$NormalLaunch
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

. (Join-Path $PSScriptRoot 'shoot-common.ps1')

$repo = Split-Path -Parent $PSScriptRoot
# Previously the exe was joined onto the repo for the config but handed to
# shoot.ps1 as given, which resolves it against the CURRENT directory - and an
# absolute -Exe was joined onto the repo too. One full path for everything.
$exeFull = Resolve-ShootExe $Exe $repo
Assert-ReleaseBuild $exeFull

# Every size this will open or shoot at, before the first launch: the
# config's placeholder the build opens at, then each capture's.
Assert-PlacementOnOneMonitor $Position (@($PlacementPlaceholder) +
    @($SIZES | ForEach-Object { @{ Width = $_.w; Height = $_.h } }))

New-Item -ItemType Directory -Path (Join-Path $repo "shots\$Phase") -Force | Out-Null

$themes = if ($Theme -eq 'both') { @($true, $false) } else { @($Theme -eq 'dark') }

# Handed to every shoot.ps1 call alongside its own arguments.
$placeArgs = @{}
if ($Position) { $placeArgs.Position = $Position }
if ($Focus) { $placeArgs.Focus = $true }

foreach ($dark in $themes) {
    $themeName = if ($dark) { 'dark' } else { 'light' }
    $suffix = if ($Accent) { "_$themeName`_accent" } else { "_$themeName" }

    Stop-AppAt $exeFull
    $settings = @{
        is_dark_theme       = $dark
        # The window opens at its stored size; start wide so the first capture
        # is not fighting a 380px restore.
        is_window_maximized = $false
        window_width        = 1600
        window_height       = 1000
        # A copied config that starts minimized would rest in the tray, and
        # shoot.ps1 waits for the app to show its own window after a launch.
        start_minimized     = $false
    }
    if ($Accent) {
        if ($dark) { $settings.dark_accent_color_hex = $Accent }
        else { $settings.light_accent_color_hex = $Accent }
    }
    if ($Position) {
        $placement = Get-PlacementSettings $Position
        foreach ($key in $placement.Keys) { $settings[$key] = $placement[$key] }
    }
    Set-IsolatedConfig $exeFull $settings

    Write-Host "=== $themeName$(if ($Accent) { " (accent $Accent)" }) ===" -ForegroundColor Cyan

    # Every capture after the launch attaches with -ExpectExe rather than
    # -LaunchExe: if the build died between captures, relaunching it would
    # silently shoot a fresh start instead of the state being reviewed.
    $first = $true
    foreach ($s in $SIZES) {
        $out = "shots/$Phase/home_$($s.label)$suffix.png"
        $shotArgs = @{
            Out       = $out
            Width     = $s.w
            Height    = $s.h
            SettleMs  = 1200
            ExpectExe = $exeFull
        }
        if ($first) {
            $shotArgs.Remove('ExpectExe')
            $shotArgs.LaunchExe = $exeFull
            $shotArgs.SettleMs = 3500     # first frame + channel load
            if (-not $NormalLaunch) { $shotArgs.NoActivate = $true }
            $first = $false
        }
        & (Join-Path $PSScriptRoot 'shoot.ps1') @shotArgs @placeArgs
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
        ExpectExe = $exeFull
    }
    & (Join-Path $PSScriptRoot 'shoot.ps1') @channelArgs @placeArgs

    $libraryArgs = @{
        Out      = "shots/$Phase/library_1600x1000$suffix.png"
        NoResize = $true
        SettleMs = 2500
        ClickAt  = '100,960'         # Library button (the gear is at ~44)
        ExpectExe = $exeFull
    }
    & (Join-Path $PSScriptRoot 'shoot.ps1') @libraryArgs @placeArgs
}

if (-not $KeepOpen) { Stop-AppAt $exeFull }
Write-Host "Matrix complete: shots/$Phase" -ForegroundColor Green
