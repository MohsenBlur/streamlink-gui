<#
.SYNOPSIS
  Captures the Twitch Streamlink GUI window to a PNG for visual review.

.DESCRIPTION
  A visual refresh cannot be verified by reasoning or by unit tests - the only
  honest check is to look at the result. This finds the app's window by class,
  optionally resizes it to an exact LOGICAL size, and captures that window
  alone (not the desktop).

  Two details that are easy to get wrong and produce a useless black image:

  * PrintWindow needs PW_RENDERFULLCONTENT (0x2). Flutter renders through a
    composited swapchain, so the legacy WM_PRINT path captures nothing.
  * MoveWindow takes PHYSICAL pixels while the app's own sizes (and the
    380x500 minimum) are LOGICAL. On a scaled display those differ, so sizes
    here are logical and converted via the window's own DPI.

  And one that produces a plausible image of the wrong thing: the top-level
  window can be visible while the engine's FLUTTERVIEW child is hidden (the
  invisible-window bug, audit C1). Only a transparent frame shows, and a
  capture "succeeds" with the desktop behind it. Every capture therefore
  asserts the child is visible first, and fails loudly when it is not.

.EXAMPLE
  ./tools/shoot.ps1 -Out shots/baseline/home_1600x1000.png -Width 1600 -Height 1000

.EXAMPLE
  # Capture whatever is on screen right now, without touching the window.
  ./tools/shoot.ps1 -Out shots/current.png -NoResize

.NOTES
  WHICH instance gets captured is the trap. The runner's single-instance
  mutex has a fixed name, so while any copy runs - typically the installed
  app resting in the tray - a dev build launched beside it exits at once, and
  the old by-class lookup then found and shot the installed app. -LaunchExe
  and -ExpectExe confine the lookup to one executable, a launch refuses to
  start while another copy holds the mutex, and every capture prints the exe
  it actually captured.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$Width,
    [int]$Height,
    [switch]$NoResize,
    # Launched when no window of THIS exe exists; any other copy of the app
    # is ignored (and, if running, makes the launch refuse - see .NOTES).
    [string]$LaunchExe,
    # Attach only to a window of this exe, and fail rather than launch it.
    [string]$ExpectExe,
    # "x,y" in logical pixels relative to the window's top-left. Clicked after
    # resizing and before capturing, so screens reachable only by navigation
    # (the Library, a channel dashboard) can be captured too.
    [string]$ClickAt,
    [int]$SettleMs = 900,
    [int]$LaunchTimeoutMs = 30000
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

Add-Type -AssemblyName System.Drawing

# The type name carries a version because Add-Type cannot redefine a type in a
# session that already loaded it: a shell that had run an older copy of this
# script would keep the old class, and the first call to a member added since
# would fail with "method not found". Bump the suffix whenever members change.
if (-not ([System.Management.Automation.PSTypeName]'Win32ShotV2').Type) {
Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class Win32ShotV2 {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public MOUSEINPUT mi; }

    // mouse_event is legacy and Flutter's Win32 input path did not observe it.
    // SendInput with absolute coordinates is the supported route; coordinates
    // are normalised to 0..65535 across the virtual desktop.
    public static void ClickAbsolute(int x, int y) {
        int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77);   // XVIRTUALSCREEN
        int vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);   // CXVIRTUALSCREEN
        int nx = (int)(((double)(x - vx) * 65535.0) / vw);
        int ny = (int)(((double)(y - vy) * 65535.0) / vh);
        const uint MOVE = 0x0001, ABS = 0x8000, VDESK = 0x4000, DOWN = 0x0002, UP = 0x0004;
        var inputs = new INPUT[3];
        for (int i = 0; i < 3; i++) { inputs[i].type = 0; inputs[i].mi.dx = nx; inputs[i].mi.dy = ny; }
        inputs[0].mi.dwFlags = MOVE | ABS | VDESK;
        inputs[1].mi.dwFlags = MOVE | ABS | VDESK | DOWN;
        inputs[2].mi.dwFlags = MOVE | ABS | VDESK | UP;
        SendInput(3, inputs, Marshal.SizeOf(typeof(INPUT)));
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    // Enumerate rather than FindWindow: the app also owns a
    // FLUTTER_RUNNER_WIN32_WINDOW_TRAY window, and the main window is HIDDEN
    // (not merely minimised) whenever the app is resting in the tray - which
    // is its normal state. Enumeration finds it in that state; we restore it
    // afterwards. ALL matches, not the first: the class is the stock Flutter
    // runner's, shared by every Flutter desktop app and every copy of this
    // one, so the caller picks by owning process.
    public static IntPtr[] FindMainWindows(string cls) {
        var found = new List<IntPtr>();
        EnumWindows((h, l) => {
            var sb = new StringBuilder(256);
            GetClassNameW(h, sb, 256);
            if (sb.ToString() == cls) found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    public static uint ProcessIdOf(IntPtr h) {
        uint procId;
        GetWindowThreadProcessId(h, out procId);
        return procId;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int index);

    // The engine's render surface is a direct child of the runner window.
    // Wrapped so the title really is null: PowerShell passes $null to a
    // string parameter as "", which would match only an untitled child.
    public static IntPtr FindChildByClass(IntPtr parent, string cls) {
        return FindWindowExW(parent, IntPtr.Zero, cls, null);
    }
}
'@
}

$WINDOW_CLASS = 'FLUTTER_RUNNER_WIN32_WINDOW'
$VIEW_CLASS = 'FLUTTERVIEW'
$APP_PROCESS = 'streamlink_gui'
$SW_RESTORE = 9
$SW_SHOW = 5
$PW_RENDERFULLCONTENT = 2
$GWL_STYLE = -16
$WS_VISIBLE = 0x10000000

function Get-WindowProcess([IntPtr]$h) {
    return Get-Process -Id ([Win32ShotV2]::ProcessIdOf($h)) -ErrorAction SilentlyContinue
}

# The app's main window - of $exePath only, when given. $null (never
# IntPtr.Zero, which PowerShell treats as TRUE) when there is none.
function Find-AppWindow([string]$exePath) {
    foreach ($h in [Win32ShotV2]::FindMainWindows($WINDOW_CLASS)) {
        $proc = Get-WindowProcess $h
        if (-not $proc -or $proc.ProcessName -ne $APP_PROCESS) { continue }
        if ($exePath -and $proc.Path -ne $exePath) { continue }
        return $h
    }
    return $null
}

# Every copy of the app in THIS logon session: the mutex is session-local, so
# a copy another user runs does not block our launch.
function Get-RunningApps {
    $session = (Get-Process -Id $PID).SessionId
    return @(Get-Process $APP_PROCESS -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $session })
}

function Format-Apps($procs) {
    return ($procs | ForEach-Object { if ($_.Path) { $_.Path } else { "pid $($_.Id)" } }) -join ', '
}

# Fails unless the engine's view inside $main is actually on screen.
#
# The invisible-window bug (audit C1): the runner window was shown and moved
# while its FLUTTERVIEW child stayed hidden (style 0x40000000, WS_CHILD with
# no WS_VISIBLE), so the user saw a transparent frame - and a capture of it
# showed the desktop behind, which reads as a rendering problem rather than a
# hidden window. IsWindowVisible on the CHILD is what tells them apart: it is
# true only when the child and every parent carry WS_VISIBLE. A short poll
# absorbs a view that appears a beat after its parent; the bug state lasts.
function Assert-ContentViewVisible([IntPtr]$main) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        $view = [Win32ShotV2]::FindChildByClass($main, $VIEW_CLASS)
        if ($view -ne [IntPtr]::Zero -and [Win32ShotV2]::IsWindowVisible($view)) { return }
        Start-Sleep -Milliseconds 250
    } while ($sw.ElapsedMilliseconds -lt 3000)

    $mainVisible = [Win32ShotV2]::IsWindowVisible($main)
    if ($view -eq [IntPtr]::Zero) {
        throw "No $VIEW_CLASS child under the app window (main visible=$mainVisible): the engine never attached its view. Capture refused."
    }
    $style = [Win32ShotV2]::GetWindowLongW($view, $GWL_STYLE)
    $flag = if (($style -band $WS_VISIBLE) -ne 0) { 'WS_VISIBLE set, so a parent is hidden' } else { 'WS_VISIBLE clear' }
    # Parenthesised: -f binds tighter than +, and would format only the last part.
    throw (("$VIEW_CLASS is not visible (main visible=$mainVisible, view style=0x{0:X8}, $flag). " +
        "The app is showing an empty frame - the invisible-window bug (audit C1) - and a capture " +
        "would show only what is behind it, so none was taken.") -f $style)
}

# --- locate, launching if asked -------------------------------------------
$targetExe = $null
if ($LaunchExe -and $ExpectExe) { throw 'Pass -LaunchExe or -ExpectExe, not both.' }
foreach ($given in @($LaunchExe, $ExpectExe)) {
    if (-not $given) { continue }
    if (-not (Test-Path $given)) { throw "Exe not found: $given" }
    $targetExe = (Resolve-Path $given).ProviderPath
}

$hwnd = Find-AppWindow $targetExe

if (-not $hwnd -and $LaunchExe) {
    # A second launch would only raise the running copy's window and exit, and
    # the capture below would then be of THAT copy. Refuse; the user's own
    # instance is theirs to quit, not ours to kill.
    $holders = Get-RunningApps
    if ($holders.Count -gt 0) {
        throw ("Another copy of the app is running: $(Format-Apps $holders). Its " +
            "single-instance mutex would make this launch exit at once and the " +
            "capture would show that copy, not $targetExe. Quit it (tray > Exit) and retry.")
    }
    Write-Host "Launching $targetExe ..." -ForegroundColor Gray
    $launched = Start-Process -FilePath $targetExe -PassThru
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $hwnd -and $sw.ElapsedMilliseconds -lt $LaunchTimeoutMs) {
        Start-Sleep -Milliseconds 300
        if ($launched.HasExited) {
            throw "$targetExe exited during startup, before it created a window."
        }
        $hwnd = Find-AppWindow $targetExe
    }
    if ($hwnd) {
        # The window exists hidden from creation; the runner shows it on the
        # first frame. Wait for the app to do that rather than showing it from
        # here: forcing it up before the first frame would be the harness
        # racing the very startup path the view check below exists to test.
        $shownSw = [Diagnostics.Stopwatch]::StartNew()
        while (-not [Win32ShotV2]::IsWindowVisible($hwnd) -and $shownSw.ElapsedMilliseconds -lt 10000) {
            Start-Sleep -Milliseconds 200
            if ($launched.HasExited) { throw "$targetExe exited during startup, after creating its window." }
        }
        if (-not [Win32ShotV2]::IsWindowVisible($hwnd)) {
            Write-Warning 'The app did not show its own window within 10s (set to start minimized?) - showing it from here.'
        }
        Start-Sleep -Milliseconds 2500   # let first frame + data settle
    }
}

if (-not $hwnd) {
    $running = Get-RunningApps
    $seen = if ($running.Count -gt 0) { "Running: $(Format-Apps $running)." } else { 'No copy of the app is running.' }
    if ($targetExe) {
        throw "No '$WINDOW_CLASS' window belongs to $targetExe. $seen"
    }
    throw "No '$WINDOW_CLASS' window of $APP_PROCESS. Start the app, or pass -LaunchExe. $seen"
}

# Say which instance this is, every time: a capture of the wrong copy looks
# exactly like a capture of the right one.
$owner = Get-WindowProcess $hwnd
$ownerPath = if ($owner -and $owner.Path) { $owner.Path } else { '<unknown path>' }
Write-Host ("Capturing {0} (pid {1})" -f $ownerPath, $owner.Id) -ForegroundColor Gray
Assert-ReleaseBuild $ownerPath

# --- size ------------------------------------------------------------------
# The window may be hidden (resting in the tray) or minimised; both must be
# undone before it will paint anything worth capturing.
$wasHidden = -not [Win32ShotV2]::IsWindowVisible($hwnd)
if ($wasHidden) {
    Write-Host 'Window was hidden (tray) - showing it for the capture.' -ForegroundColor Gray
    [Win32ShotV2]::ShowWindow($hwnd, $SW_SHOW) | Out-Null
}
[Win32ShotV2]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
[Win32ShotV2]::SetForegroundWindow($hwnd) | Out-Null

if (-not $NoResize) {
    if (-not $Width -or -not $Height) { throw 'Provide -Width and -Height, or pass -NoResize.' }
    $dpi = [Win32ShotV2]::GetDpiForWindow($hwnd)
    if ($dpi -le 0) { $dpi = 96 }
    $scale = $dpi / 96.0
    $pw = [int][Math]::Round($Width * $scale)
    $ph = [int][Math]::Round($Height * $scale)
    Write-Host ("Resizing to {0}x{1} logical ({2}x{3} physical @ {4} dpi)" -f $Width, $Height, $pw, $ph, $dpi) -ForegroundColor Gray
    [Win32ShotV2]::MoveWindow($hwnd, 80, 60, $pw, $ph, $true) | Out-Null
}

Start-Sleep -Milliseconds $SettleMs   # let Flutter relayout and repaint

# Before the click too: a click on a hidden view lands on whatever is behind.
Assert-ContentViewVisible $hwnd

if ($ClickAt) {
    $parts = $ClickAt.Split(',')
    if ($parts.Count -ne 2) { throw "ClickAt must be 'x,y'." }
    $r0 = New-Object Win32ShotV2+RECT
    [Win32ShotV2]::GetWindowRect($hwnd, [ref]$r0) | Out-Null
    $rect0Right = $r0.Right
    $dpiC = [Win32ShotV2]::GetDpiForWindow($hwnd); if ($dpiC -le 0) { $dpiC = 96 }
    $sc = $dpiC / 96.0
    $cx = $r0.Left + [int]([double]$parts[0].Trim() * $sc)
    $cy = $r0.Top  + [int]([double]$parts[1].Trim() * $sc)
    Write-Host "Clicking at $cx,$cy" -ForegroundColor Gray
    # PrintWindow captures an occluded window happily, so a shot can look
    # correct while the app sits BEHIND the terminal - and a synthetic click at
    # screen coordinates then lands on whatever is actually on top. Raise it
    # for the duration of the click, and verify what is under the cursor.
    $HWND_TOPMOST = New-Object IntPtr(-1)
    $HWND_NOTOPMOST = New-Object IntPtr(-2)
    $SWP_NOMOVE_NOSIZE_NOACTIVATE = 0x0002 -bor 0x0001 -bor 0x0010
    [Win32ShotV2]::SetWindowPos($hwnd, $HWND_TOPMOST, 0, 0, 0, 0, $SWP_NOMOVE_NOSIZE_NOACTIVATE) | Out-Null
    [Win32ShotV2]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 350

    $pt = New-Object Win32ShotV2+POINT
    $pt.X = $cx; $pt.Y = $cy
    $under = [Win32ShotV2]::WindowFromPoint($pt)
    $sb = New-Object System.Text.StringBuilder 256
    [Win32ShotV2]::GetClassNameW($under, $sb, 256) | Out-Null
    # FLUTTERVIEW is the app's own child render surface, so it counts as a hit.
    $hitClass = $sb.ToString()
    if ($hitClass -ne $WINDOW_CLASS -and $hitClass -ne 'FLUTTERVIEW') {
        Write-Warning "Point ($cx,$cy) belongs to '$hitClass', not the app - the click will miss."
    }

    [Win32ShotV2]::ClickAbsolute($cx, $cy)
    Start-Sleep -Milliseconds 900
    # NOTE: topmost is NOT dropped here. Doing so immediately after the click
    # let the window fall behind, and PrintWindow then captured a released
    # compositor surface - a uniformly #B5B5B5 rectangle that looks exactly
    # like a crash. It is restored after the capture instead.
    $script:restoreTopmost = $true

    # Park the cursor off the window before capturing. Leaving it where it
    # clicked leaves a hover highlight on whatever is under it, which shows up
    # as a real-looking difference when comparing two phases' captures.
    [Win32ShotV2]::SetCursorPos($rect0Right + 40, $r0.Top + 4) | Out-Null
    Start-Sleep -Milliseconds 500
}

# --- capture ---------------------------------------------------------------
$rect = New-Object Win32ShotV2+RECT
[Win32ShotV2]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
if ($w -le 0 -or $h -le 0) { throw "Window has no area ($w x $h)." }

$bmp = New-Object System.Drawing.Bitmap($w, $h)
try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $hdc = $g.GetHdc()
        try {
            # PW_RENDERFULLCONTENT is load-bearing: without it a Flutter window
            # captures as a black rectangle.
            $ok = [Win32ShotV2]::PrintWindow($hwnd, $hdc, $PW_RENDERFULLCONTENT)
            if (-not $ok) { throw 'PrintWindow failed.' }
        } finally { $g.ReleaseHdc($hdc) }
    } finally { $g.Dispose() }

    $dir = Split-Path -Parent $Out
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bmp.Save((Join-Path (Get-Location) $Out), [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $bmp.Dispose() }

# Guard against the classic silent failure: a uniformly blank capture.
# Sample a grid rather than two points: a large flat background made a
# two-pixel test cry wolf on almost every light-theme capture.
$check = [System.Drawing.Bitmap]::FromFile((Join-Path (Get-Location) $Out))
try {
    $seen = @{}
    foreach ($fx in 0.1, 0.3, 0.5, 0.7, 0.9) {
        foreach ($fy in 0.1, 0.3, 0.5, 0.7, 0.9) {
            $c = $check.GetPixel([int]($check.Width * $fx), [int]($check.Height * $fy))
            $seen['{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B] = $true
        }
    }
    $uniform = ($seen.Count -le 1)
} finally { $check.Dispose() }

if ($script:restoreTopmost) {
    [Win32ShotV2]::SetWindowPos($hwnd, (New-Object IntPtr(-2)), 0, 0, 0, 0, 0x0002 -bor 0x0001 -bor 0x0010) | Out-Null
}

Write-Host ("Saved {0} ({1}x{2})" -f $Out, $w, $h) -ForegroundColor Green
if ($uniform) { Write-Warning 'Capture may be blank - two sampled pixels are identical. Check PW_RENDERFULLCONTENT and that the window is not occluded.' }
