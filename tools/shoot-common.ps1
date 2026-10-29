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

# The settings keys holding credentials: AppSettings.secretJsonKeys
# (lib/models/app_settings.dart), read from the source rather than copied
# here, so a token field added there is blanked by Set-IsolatedConfig too.
# Throws rather than stage a config whose tokens it could not find.
function Get-SecretSettingKeys {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\models\app_settings.dart'
    if (-not (Test-Path -LiteralPath $src)) { throw "Cannot find $src to read AppSettings.secretJsonKeys from." }
    $text = Get-Content -LiteralPath $src -Raw -Encoding UTF8
    $list = [regex]::Match($text, 'secretJsonKeys\s*=\s*\[(?<keys>[^\]]*)\]')
    $keys = @()
    if ($list.Success) {
        $keys = @([regex]::Matches($list.Groups['keys'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    }
    if ($keys.Count -eq 0) {
        throw "Could not read AppSettings.secretJsonKeys from $src; refusing to stage a config whose tokens might not be blanked."
    }
    return $keys
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
#
# Every token in it is blanked (Get-SecretSettingKeys), on every call. The
# real config's tokens are DPAPI-sealed, and DPAPI opens them again for the
# same Windows user, so a straight copy signed the build under test in as the
# user's own Twitch account and left one more copy of the tokens beside a
# build folder. Blanked, the build runs with no account: captures of the
# channel screen show no VOD list. A staged config from before this is
# blanked the same way, and $settings is applied after that, so a caller can
# still hand it a test token on purpose.
#
# launch_at_startup is forced off after everything else, $settings
# included. The copy carries the user's own "Launch at startup", and a build
# that starts with it on rewrites the HKCU Run value to ITS exe at every
# launch (StartupService().sync(true) in main.dart, to heal a moved
# install): one capture and the user's login started the build under test
# instead of their app.
#
# -NoActivate stages a window that is not maximized, for a launch with
# Start-AppNoActivate. The runner applies the launcher's SW_SHOWNOACTIVATE to
# its first show itself now (Win32Window::SetLaunchShowCommand), maximized
# included. A build from before that left it to Windows, which swaps the
# launcher's command in only for a plain first show: a placement saved
# maximized made that first show SW_SHOWMAXIMIZED, which Windows leaves
# alone (measured), and the window came up maximized and active. Staged
# unmaximized, such a build stays in the background too.
function Set-IsolatedConfig([string]$exePath, [hashtable]$settings, [switch]$NoActivate) {
    $relDir = Split-Path -Parent $exePath
    $marker = Join-Path $relDir 'portable.txt'
    if (-not (Test-Path $marker)) { New-Item -ItemType File -Path $marker | Out-Null }

    $cfgPath = Join-Path $relDir 'channels_config.json'
    $srcCfg = $cfgPath
    if (-not (Test-Path $cfgPath)) {
        $srcCfg = Join-Path $env:APPDATA 'TwitchStreamlinkGUI\channels_config.json'
        if (-not (Test-Path $srcCfg)) {
            throw "No config to stage: neither $cfgPath nor $srcCfg exists. Run the app once (or copy a config to $cfgPath) first."
        }
    }

    # Read, blanked, and only then written beside the exe: Copy-Item put the
    # file there with its tokens first. UTF8 explicitly, as the app writes it
    # without a BOM and Windows PowerShell would otherwise read it as ANSI.
    $json = Get-Content -LiteralPath $srcCfg -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $json.settings) {
        throw "$srcCfg has no 'settings' object - not a Streamlink GUI config?"
    }
    foreach ($key in Get-SecretSettingKeys) {
        $json.settings | Add-Member -NotePropertyName $key -NotePropertyValue '' -Force
    }
    foreach ($key in $settings.Keys) {
        $json.settings | Add-Member -NotePropertyName $key -NotePropertyValue $settings[$key] -Force
    }
    $json.settings | Add-Member -NotePropertyName 'launch_at_startup' -NotePropertyValue $false -Force
    if ($NoActivate) {
        $json.settings | Add-Member -NotePropertyName 'is_window_maximized' -NotePropertyValue $false -Force
    }
    # Windows PowerShell's utf8 writes a BOM; the app's reader (dart:io
    # readAsString) strips it, so the file still loads.
    $json | ConvertTo-Json -Depth 64 | Set-Content $cfgPath -Encoding utf8
}

# Config settings that open the window at $position ("x,y", physical
# virtual-desktop pixels) rather than where the copied config last left it.
#
# The staged config starts as a copy of the user's own, so without this a
# launch opens the build wherever the user keeps the app - on their working
# monitor, maximised if they keep it so - before shoot.ps1 -Position could
# move it. The size is a placeholder; shoot.ps1 sizes the window itself.
# Physical, as the app stores it.
$PlacementPlaceholder = @{ Width = 1280; Height = 720; Physical = $true }

function Get-PlacementSettings([string]$position) {
    $parts = $position.Split(',')
    if ($parts.Count -ne 2) { throw "-Position must be 'x,y'." }
    return @{
        is_window_maximized = $false
        window_placement    = @{
            left   = [int]$parts[0].Trim()
            top    = [int]$parts[1].Trim()
            width  = $PlacementPlaceholder.Width
            height = $PlacementPlaceholder.Height
        }
    }
}

# --- launching without taking the foreground, placing on one monitor -------

# Versioned type name: Add-Type cannot redefine a type in a session that
# already loaded an older copy (see shoot.ps1). Bump it when members change.
if (-not ([System.Management.Automation.PSTypeName]'ShootCommonV1').Type) {
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class ShootCommonV1 {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);

    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 for the calling thread, so
    // monitor rects are physical pixels (see shoot.ps1). False if unavailable.
    public static bool PerMonitorAware() {
        return SetThreadDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero;
    }

    // Every monitor's full rect (not its work area), virtual-desktop pixels.
    public static RECT[] MonitorRects() {
        var found = new List<RECT>();
        MonitorEnumProc each = (IntPtr m, IntPtr dc, ref RECT r, IntPtr d) => { found.Add(r); return true; };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, each, IntPtr.Zero);
        GC.KeepAlive(each);
        return found.ToArray();
    }

    // The effective DPI of the monitor at (or nearest) a point; 96 if unknown.
    public static uint DpiAt(int x, int y) {
        var pt = new POINT(); pt.X = x; pt.Y = y;
        IntPtr monitor = MonitorFromPoint(pt, 2);   // MONITOR_DEFAULTTONEAREST
        uint dx, dy;
        if (monitor == IntPtr.Zero || GetDpiForMonitor(monitor, 0, out dx, out dy) != 0 || dx == 0) return 96;
        return dx;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcessW(string app, System.Text.StringBuilder cmd, IntPtr procAttrs, IntPtr threadAttrs,
        bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    // Starts `exe` in `dir` with STARTF_USESHOWWINDOW and SW_SHOWNOACTIVATE,
    // and returns its process id. The runner applies a launcher's show
    // command to its first show, so the window comes up without activating
    // (see Set-IsolatedConfig -NoActivate for builds from before that).
    public static int StartNoActivate(string exe, string dir) {
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.dwFlags = 0x00000001;   // STARTF_USESHOWWINDOW
        si.wShowWindow = 4;        // SW_SHOWNOACTIVATE
        PROCESS_INFORMATION pi;
        var cmd = new System.Text.StringBuilder("\"" + exe + "\"");
        if (!CreateProcessW(exe, cmd, IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, dir, ref si, out pi)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return pi.dwProcessId;
    }
}
'@
}

# Launches $exePath without making its window the active one, and returns
# its process.
#
# Start-Process launches it to be shown normally, and the runner's first show
# then activates the window: keyboard focus pulled from whatever the user was
# typing into, once per launch - and the matrix launches once per theme, the
# materials script once per shot. The working directory is the exe's own, as
# a shortcut or the updater's relaunch would give it.
#
# The show command only reaches the first show; the runner keeps everything
# before it from taking the foreground for such a launch too
# (Win32Window::SetStartInBackground). A 20ms foreground sampler showed the
# still hidden window taking it at process start in builds from before
# that: once by the runner's own SetFocus, and again by window_manager's
# title bar setup. Such a build still takes it whenever Windows lets it,
# however it is launched.
function Start-AppNoActivate([string]$exePath) {
    $procId = [ShootCommonV1]::StartNoActivate($exePath, (Split-Path -Parent $exePath))
    return [Diagnostics.Process]::GetProcessById($procId)
}

# Whether the config a portable $exePath reads beside itself would open its
# window maximized - the first show Start-AppNoActivate could not keep from
# activating in builds from before the runner applied the launcher's command
# itself (see Set-IsolatedConfig -NoActivate). $false when it
# is not portable, has no config there, or the config cannot be read: the
# question is only asked to warn.
function Test-StagedOpensMaximized([string]$exePath) {
    $dir = Split-Path -Parent $exePath
    $cfg = Join-Path $dir 'channels_config.json'
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'portable.txt'))) { return $false }
    if (-not (Test-Path -LiteralPath $cfg)) { return $false }
    try {
        $json = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
        return ($json.settings.is_window_maximized -eq $true)
    } catch {
        return $false
    }
}

# Every monitor as Left/Top/Right/Bottom (physical, right and bottom
# exclusive) and its Dpi.
function Get-Monitors {
    if (-not [ShootCommonV1]::PerMonitorAware()) {
        Write-Warning 'Could not make this thread per-monitor DPI aware: monitor bounds on a scaled monitor will be logical, and the -Position check may misjudge them.'
    }
    return @([ShootCommonV1]::MonitorRects() | ForEach-Object {
        [pscustomobject]@{
            Left = $_.Left; Top = $_.Top; Right = $_.Right; Bottom = $_.Bottom
            Dpi = [int][ShootCommonV1]::DpiAt($_.Left, $_.Top)
        }
    })
}

function Format-Monitor($m) {
    return '({0},{1})-({2},{3}) @ {4} dpi' -f $m.Left, $m.Top, $m.Right, $m.Bottom, $m.Dpi
}

# The monitor a point is on, or the nearest one to it.
function Get-NearestMonitor([int]$x, [int]$y, [object[]]$monitors) {
    $best = $null
    $bestDistance = [double]::MaxValue
    foreach ($m in $monitors) {
        $dx = [Math]::Max([Math]::Max($m.Left - $x, 0), $x - ($m.Right - 1))
        $dy = [Math]::Max([Math]::Max($m.Top - $y, 0), $y - ($m.Bottom - 1))
        $distance = [double]$dx * $dx + [double]$dy * $dy
        if ($distance -lt $bestDistance) { $best = $m; $bestDistance = $distance }
    }
    return $best
}

# Why a window with its top-left at ($x,$y) would cover more than one
# monitor, or $null when it would not. Pure, so the tests can hand it
# monitors of their own.
#
# $width and $height are logical unless $physical: the app keeps its logical
# size, so its physical size is that at the DPI of the monitor it lands on -
# the one nearest the top-left, measured again with the DPI of the one it
# then covers when that differs. Overhang past the desktop's edge, onto no
# monitor, is fine: the examples rely on it.
function Find-PlacementOverhang([int]$x, [int]$y, [int]$width, [int]$height, [object[]]$monitors, [switch]$physical) {
    $onto = Get-NearestMonitor $x $y $monitors
    if (-not $onto) { return $null }
    for ($pass = 0; $pass -lt 2; $pass++) {
        $scale = if ($physical) { 1.0 } else { $onto.Dpi / 96.0 }
        $pw = [int][Math]::Round($width * $scale)
        $ph = [int][Math]::Round($height * $scale)
        $covered = @($monitors | Where-Object {
            $x -lt $_.Right -and ($x + $pw) -gt $_.Left -and $y -lt $_.Bottom -and ($y + $ph) -gt $_.Top
        })
        if ($covered.Count -gt 1) {
            $unit = if ($physical) { 'physical' } else { "logical, ${pw}x${ph} physical at $($onto.Dpi) dpi" }
            return ("a {0}x{1} window ({2}) at ({3},{4}) reaches ({5},{6}) and covers {7} monitors: {8}" -f
                $width, $height, $unit, $x, $y, ($x + $pw), ($y + $ph), $covered.Count,
                (($covered | ForEach-Object { Format-Monitor $_ }) -join ', '))
        }
        if ($physical -or $covered.Count -eq 0 -or $covered[0].Dpi -eq $onto.Dpi) { return $null }
        $onto = $covered[0]
    }
    return $null
}

# Refuses a -Position from which any of $sizes would put the window across
# two monitors. Each size is @{ Width; Height } (logical), or with
# Physical = $true for a size already in physical pixels.
#
# -Position exists to keep the window off the monitor the user works on, and
# a size that grows past the chosen monitor's edge spills onto the next one -
# in the examples, the primary - with nothing to say so.
function Assert-PlacementOnOneMonitor([string]$position, [object[]]$sizes) {
    if (-not $position) { return }
    $parts = $position.Split(',')
    if ($parts.Count -ne 2) { throw "-Position must be 'x,y'." }
    $x = [int]$parts[0].Trim()
    $y = [int]$parts[1].Trim()
    $monitors = Get-Monitors
    foreach ($size in $sizes) {
        $why = Find-PlacementOverhang $x $y $size.Width $size.Height $monitors -physical:([bool]$size.Physical)
        if ($why) {
            throw ("-Position '$position' would put the window across two monitors: $why. " +
                'Refused before the window was placed there. Pick a position from which the whole window ' +
                'fits on one monitor (running past the desktop''s outer edge is fine).')
        }
    }
}
