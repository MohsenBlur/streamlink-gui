<#
.SYNOPSIS
  Helpers shared by the screenshot scripts that LAUNCH the app.

.DESCRIPTION
  Dot-source it: . (Join-Path $PSScriptRoot 'shoot-common.ps1')

  shoot-matrix.ps1 and shoot-materials.ps1 each grew their own copy of "stop
  the app, point it at a config, relaunch", and the copies drifted: only the
  matrix isolated its config, and both stopped processes by NAME. These are the
  one version both use.
#>

# A launch script accepts a repo-relative or absolute exe and must hand the
# SAME full path to everything else - the config staging below, the process
# filter, and shoot.ps1 (which resolves relative paths against the current
# directory, not the repo).
function Resolve-ShootExe([string]$exe, [string]$repo) {
    $full = if ([IO.Path]::IsPathRooted($exe)) { $exe } else { Join-Path $repo $exe }
    $full = [IO.Path]::GetFullPath($full)
    if (-not (Test-Path $full)) {
        throw "Build not found at $full - flutter build windows --release first."
    }
    return $full
}

# Stops the build under test, and nothing else.
#
# `Get-Process streamlink_gui | Stop-Process -Force` also matched the INSTALLED
# app - both executables have the same name - so taking a screenshot killed the
# user's real instance in the middle of a VOD download and left a partial file.
# Matching the full path confines it to the build being shot. (-eq on strings is
# case-insensitive, as Windows paths are.)
function Stop-AppAt([string]$exePath) {
    Get-Process streamlink_gui -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $exePath } |
        ForEach-Object { $_.Kill(); $_.WaitForExit(5000) | Out-Null }
    Start-Sleep -Milliseconds 600
}

# Points the build at a config of its own, then applies $settings to it.
#
# Without a portable.txt marker beside the exe the app ignores a config staged
# there and reads %APPDATA% (StorageService.getStorageFile), so a script that
# only edited the staged file captured the user's real settings while reporting
# success - six "different" material shots of the same material. The marker
# makes the app read and write beside itself; the user's live settings and
# OAuth token are never written to.
#
# The staged config starts as a copy of the real one so captures show real
# channels. Keys are set with Add-Member -Force because a property missing from
# an older config cannot be assigned on a PSCustomObject - it throws.
function Set-IsolatedConfig([string]$exePath, [hashtable]$settings) {
    $relDir = Split-Path -Parent $exePath
    $marker = Join-Path $relDir 'portable.txt'
    if (-not (Test-Path $marker)) { New-Item -ItemType File -Path $marker | Out-Null }

    $cfgPath = Join-Path $relDir 'channels_config.json'
    if (-not (Test-Path $cfgPath)) {
        $srcCfg = Join-Path $env:APPDATA 'TwitchStreamlinkGUI\channels_config.json'
        if (-not (Test-Path $srcCfg)) {
            throw "No config to stage: neither $cfgPath nor $srcCfg exists. Run the app once (or copy a config to $cfgPath) first."
        }
        Copy-Item $srcCfg $cfgPath -Force
    }

    $json = Get-Content $cfgPath -Raw | ConvertFrom-Json
    if (-not $json.settings) {
        throw "$cfgPath has no 'settings' object - not a Streamlink GUI config?"
    }
    foreach ($key in $settings.Keys) {
        $json.settings | Add-Member -NotePropertyName $key -NotePropertyValue $settings[$key] -Force
    }
    # Windows PowerShell's utf8 writes a BOM; the app's reader (dart:io
    # readAsString) strips it, so the file still loads.
    $json | ConvertTo-Json -Depth 64 | Set-Content $cfgPath -Encoding utf8
}
