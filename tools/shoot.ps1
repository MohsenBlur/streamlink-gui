<#
.SYNOPSIS
  Captures the Twitch Streamlink GUI window to a PNG for visual review.

.DESCRIPTION
  A visual refresh cannot be verified by reasoning or by unit tests - the only
  honest check is to look at the result. This finds the app's main window
  (see .NOTES for which one), optionally resizes it to an exact LOGICAL size,
  and captures that window alone (not the desktop).

  Two details that are easy to get wrong and produce a useless black image:

  * PrintWindow needs PW_RENDERFULLCONTENT (0x2). Flutter renders through a
    composited swapchain, so the legacy WM_PRINT path captures nothing.
  * SetWindowPos takes PHYSICAL pixels while the app's own sizes (and the
    380x500 minimum) are LOGICAL. On a scaled display those differ, so sizes
    here are logical and converted via the window's own DPI.
  * The script must itself be per-monitor DPI aware, and is made so on its
    own thread. Windows PowerShell is a DPI-unaware host, and Windows hands
    such a host a virtualized, scaled-down view of any window on a scaled
    monitor: GetWindowRect reported a window on the 150% monitor at its
    logical size, so the bitmap was two thirds as wide and tall as the
    window and the capture came out cropped to its top-left corner.

  And one that produces a plausible image of the wrong thing: the top-level
  window can be visible while the engine's FLUTTERVIEW child is hidden (the
  invisible-window bug, audit C1). Only a transparent frame shows, and a
  capture "succeeds" with the desktop behind it. Every capture therefore
  asserts the child is visible first, and fails loudly when it is not.

  The window is left where it is and is never brought to the foreground
  unless asked (-Position, -Focus): PrintWindow renders a window that is not
  in front, so neither is needed for a capture. The script used to move every
  window it resized to (80,60), which is on the primary monitor, and to call
  SetForegroundWindow before each capture, which took keyboard focus from
  whatever the user was typing into. -ClickAt keeps to that: its click is
  POSTED, as tools/click.ps1 posts one - a mouse move, button down and
  button up sent straight to the engine's FLUTTERVIEW in its own client
  coordinates - so the cursor does not move and the window is neither
  activated nor raised. -RealInput clicks with SendInput instead, the way it
  used to: that moves the cursor (put back afterwards), raises the window
  for the click and, like any click, activates it.

  A launch (-LaunchExe) is shown the way a user's launch is, which makes the
  new window the active one: this script is the invisible-window check
  (audit C1), and that is the startup path it exists to test. -NoActivate
  launches it with SW_SHOWNOACTIVATE instead, for scripts that launch many
  times (shoot-matrix.ps1 and shoot-materials.ps1 do by default). That keeps
  the show from activating the window, and the runner keeps the hidden
  window from taking the foreground before it (shoot-common.ps1,
  Start-AppNoActivate). A config that opens the window maximized defeats it
  in builds from before the runner applied the launcher's show command
  itself, so the launch warns about one; shoot-common.ps1's
  Set-IsolatedConfig -NoActivate stages the window unmaximized.

  -Position is refused, before the window is moved, when the window it would
  produce - its size scaled to the DPI of the monitor it lands on - would
  reach onto a second monitor: the point of -Position is to keep the window
  off the monitor the user is working on.

.EXAMPLE
  ./tools/shoot.ps1 -Out shots/baseline/home_1600x1000.png -Width 1600 -Height 1000

.EXAMPLE
  # Capture whatever is on screen right now, without touching the window.
  ./tools/shoot.ps1 -Out shots/current.png -NoResize

.EXAMPLE
  # Put a staged portable build on a second monitor first. -Position is in
  # physical virtual-desktop pixels; a monitor left of the primary has
  # negative X.
  ./tools/shoot.ps1 -Out shots/home.png -Width 900 -Height 600 -ExpectExe $exe -Position '-2160,-813'

.NOTES
  WHICH instance gets captured is the trap. A second launch in the same
  single-instance scope hands over to the running copy and exits at once,
  and the old by-class lookup then found and shot that copy instead.
  -LaunchExe and -ExpectExe confine the lookup to one executable, and every
  capture prints the exe it actually captured. Within it, the window is the
  one the runner marks as the main window (the TwitchStreamlinkGUI.MainWindow
  property, windows/runner/single_instance.cpp), as tools/click.ps1 picks it:
  the class alone is the stock Flutter runner's. A build from before that
  property is found by class instead, and only when its exe is named.

  A launch refuses only when a running copy shares the new one's scope
  (windows/runner/single_instance.cpp). A portable copy - portable.txt
  beside its exe, which shoot-common.ps1's Set-IsolatedConfig writes - is a
  scope of its own, keyed by its folder, so the installed app resting in the
  tray no longer blocks a portable build; another copy from the same folder
  still does. A non-portable build shares %APPDATA%, and the one scope, with
  every other non-portable copy, the installed app included. A copy whose
  path cannot be read (elevated) is assumed to conflict.
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
    # (the Library, a channel dashboard) can be captured too. Posted to the
    # app's view unless -RealInput (see .DESCRIPTION).
    [string]$ClickAt,
    # With -ClickAt: a real, synthesized click (SendInput) rather than a
    # posted one. It moves the cursor and activates the window.
    [switch]$RealInput,
    # "x,y": move the window's top-left here before sizing it, in PHYSICAL
    # virtual-desktop pixels. Without it the window stays where it is - where
    # the app's own config put it. A size larger than the room left on that
    # monitor grows the window past its right or bottom edge.
    [string]$Position,
    # Bring the window to the foreground before capturing. Not needed for
    # PrintWindow, and it takes keyboard focus from the user's own window.
    [switch]$Focus,
    # With -LaunchExe: start the app with SW_SHOWNOACTIVATE, so its first
    # show does not make it the active window (see .DESCRIPTION).
    [switch]$NoActivate,
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

# Start-AppNoActivate and Assert-PlacementOnOneMonitor.
. (Join-Path $PSScriptRoot 'shoot-common.ps1')

Add-Type -AssemblyName System.Drawing

# The type name carries a version because Add-Type cannot redefine a type in a
# session that already loaded it: a shell that had run an older copy of this
# script would keep the old class, and the first call to a member added since
# would fail with "method not found". Bump the suffix whenever members change.
if (-not ([System.Management.Automation.PSTypeName]'Win32ShotV5').Type) {
Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class Win32ShotV5 {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);

    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 for the calling thread, which
    // runs the whole script: rects, SetWindowPos, the cursor and the virtual
    // desktop metrics are then all physical pixels. False if unavailable.
    public static bool PerMonitorAware() {
        return SetThreadDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero;
    }
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetPropW(IntPtr h, string name);
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

    // Enumerate rather than FindWindow: the main window is HIDDEN (not
    // merely minimised) whenever the app is resting in the tray - which is
    // its normal state - and enumeration finds it in that state.
    //
    // The top-level windows of `pid` that carry the runner's main-window
    // property: not the tray's FLUTTER_RUNNER_WIN32_WINDOW_TRAY window, and
    // never a window of another process.
    public static IntPtr[] TaggedWindowsOf(uint pid, string prop) {
        var found = new List<IntPtr>();
        EnumWindows((h, l) => {
            if (ProcessIdOf(h) == pid && GetPropW(h, prop) != IntPtr.Zero) found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    // The same by window class, for builds from before the property. The
    // class is the stock Flutter runner's, so only ever ask it of one
    // process.
    public static IntPtr[] ClassWindowsOf(uint pid, string cls) {
        var found = new List<IntPtr>();
        EnumWindows((h, l) => {
            if (ProcessIdOf(h) != pid) return true;
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

    [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);

    // One posted mouse message, client coordinates packed as a real one's
    // (tools/click.ps1 posts its clicks the same way).
    public static bool PostMouse(IntPtr view, uint msg, uint keys, int x, int y) {
        IntPtr lp = new IntPtr((y << 16) | (x & 0xFFFF));
        return PostMessageW(view, msg, new IntPtr(keys), lp);
    }
}
'@
}

# Before any window is measured: see the DPI note at the top.
if (-not [Win32ShotV5]::PerMonitorAware()) {
    Write-Warning 'Could not make this script per-monitor DPI aware: a window on a scaled monitor will be measured, and captured, at its logical size.'
}

$WINDOW_CLASS = 'FLUTTER_RUNNER_WIN32_WINDOW'
$MAIN_WINDOW_PROP = 'TwitchStreamlinkGUI.MainWindow'
$VIEW_CLASS = 'FLUTTERVIEW'
$APP_PROCESS = 'streamlink_gui'
# Neither activates the window: see "show, place, size" below.
$SW_SHOWNOACTIVATE = 4   # restores a minimised or maximised window
$SW_SHOWNA = 8           # shows a hidden window in its current state
$SWP_NOSIZE = 0x0001
$SWP_NOMOVE = 0x0002
$SWP_NOZORDER = 0x0004
$SWP_NOACTIVATE = 0x0010
$GA_ROOT = 2
$PW_RENDERFULLCONTENT = 2
$GWL_STYLE = -16
$WS_VISIBLE = 0x10000000

function Get-WindowProcess([IntPtr]$h) {
    return Get-Process -Id ([Win32ShotV5]::ProcessIdOf($h)) -ErrorAction SilentlyContinue
}

# "x,y" to two numbers, or a clear error naming the parameter.
function ConvertTo-Point([string]$text, [string]$name) {
    $parts = $text.Split(',')
    if ($parts.Count -ne 2) { throw "$name must be 'x,y'." }
    return @([double]$parts[0].Trim(), [double]$parts[1].Trim())
}

# The app's main window - of $exePath only, when given. $null (never
# IntPtr.Zero, which PowerShell treats as TRUE) when there is none.
#
# Picked as tools/click.ps1 picks it: a window of a streamlink_gui process
# carrying the runner's main-window property. A build older than the
# property has none, and is looked up by class instead - only for a named
# exe, because by class the user's own older copy is as good a match as the
# build under test.
function Find-AppWindow([string]$exePath) {
    $found = @()
    $untagged = @()
    foreach ($proc in @(Get-Process $APP_PROCESS -ErrorAction SilentlyContinue)) {
        if ($exePath -and $proc.Path -ne $exePath) { continue }
        $tagged = @([Win32ShotV5]::TaggedWindowsOf([uint32]$proc.Id, $MAIN_WINDOW_PROP))
        if ($tagged.Count -gt 1) {
            throw "pid $($proc.Id) has $($tagged.Count) windows tagged $MAIN_WINDOW_PROP; refusing to guess which one to capture."
        }
        if ($tagged.Count -eq 1) { $found += $tagged[0]; continue }
        if ($exePath) { $untagged += @([Win32ShotV5]::ClassWindowsOf([uint32]$proc.Id, $WINDOW_CLASS)) }
    }
    if ($found.Count -eq 0 -and $untagged.Count -gt 0) {
        if ($untagged.Count -gt 1) {
            throw "$exePath has $($untagged.Count) '$WINDOW_CLASS' windows and no $MAIN_WINDOW_PROP tag; refusing to guess which one to capture."
        }
        Write-Warning "$exePath has no window tagged $MAIN_WINDOW_PROP (a build from before the tag); using its '$WINDOW_CLASS' window."
        return $untagged[0]
    }
    if ($found.Count -eq 0) { return $null }
    # Now that a portable build can run beside the installed app, "the app's
    # window" can mean two different copies. Only a named exe may pick.
    if (-not $exePath -and $found.Count -gt 1) {
        $owners = ($found | ForEach-Object { $p = Get-WindowProcess $_; if ($p.Path) { $p.Path } else { "pid $($p.Id)" } }) -join ', '
        throw "Several copies of the app have a window ($owners). Pass -ExpectExe to say which one to capture."
    }
    return $found[0]
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

# The runner's single-instance scope for an exe: its own folder when it runs
# portable, else the one scope every non-portable copy shares.
function Get-InstanceScope([string]$exePath) {
    $dir = Split-Path -Parent $exePath
    if (Test-Path -LiteralPath (Join-Path $dir 'portable.txt') -PathType Leaf) {
        return "portable:$($dir.ToLowerInvariant())"
    }
    return 'shared'
}

# The running copies a launch of $exePath would hand over to, and exit.
function Get-ConflictingApps([string]$exePath) {
    $scope = Get-InstanceScope $exePath
    return @(Get-RunningApps | Where-Object { -not $_.Path -or (Get-InstanceScope $_.Path) -eq $scope })
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
        $view = [Win32ShotV5]::FindChildByClass($main, $VIEW_CLASS)
        if ($view -ne [IntPtr]::Zero -and [Win32ShotV5]::IsWindowVisible($view)) { return }
        Start-Sleep -Milliseconds 250
    } while ($sw.ElapsedMilliseconds -lt 3000)

    $mainVisible = [Win32ShotV5]::IsWindowVisible($main)
    if ($view -eq [IntPtr]::Zero) {
        throw "No $VIEW_CLASS child under the app window (main visible=$mainVisible): the engine never attached its view. Capture refused."
    }
    $style = [Win32ShotV5]::GetWindowLongW($view, $GWL_STYLE)
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

if ($Position -and -not $NoResize -and $Width -and $Height) {
    # Before anything launches, where the size is already known.
    Assert-PlacementOnOneMonitor $Position @(@{ Width = $Width; Height = $Height })
}

$hwnd = Find-AppWindow $targetExe

if (-not $hwnd -and $LaunchExe) {
    # A launch in the scope of a running copy would only raise that copy's
    # window and exit, and the capture below would then be of THAT copy.
    # Refuse; the user's own instance is theirs to quit, not ours to kill.
    # A copy in another scope is no obstacle (see .NOTES).
    $holders = Get-ConflictingApps $targetExe
    if ($holders.Count -gt 0) {
        $why = if ((Get-InstanceScope $targetExe) -eq 'shared') {
            'Neither runs portable, so they share one single-instance scope'
        } else {
            'It runs from the same portable folder, so they share one single-instance scope'
        }
        throw ("Another copy of the app is running: $(Format-Apps $holders). $why, " +
            "this launch would exit at once and the capture would show that copy, " +
            "not $targetExe. Quit it (tray > Exit), or stage the build portable " +
            "(shoot-common.ps1 Set-IsolatedConfig), and retry.")
    }
    if ($NoActivate) {
        if (Test-StagedOpensMaximized $targetExe) {
            Write-Warning ("The config beside $targetExe opens the window maximized, and a build from " +
                "before the runner applied the launcher's show command itself activates a maximized " +
                'first show despite -NoActivate. Stage it with Set-IsolatedConfig -NoActivate ' +
                '(shoot-common.ps1) to keep the launch in the background.')
        }
        Write-Host "Launching $targetExe without activating it ..." -ForegroundColor Gray
        $launched = Start-AppNoActivate $targetExe
    } else {
        Write-Host "Launching $targetExe ..." -ForegroundColor Gray
        $launched = Start-Process -FilePath $targetExe -PassThru
    }
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
        while (-not [Win32ShotV5]::IsWindowVisible($hwnd) -and $shownSw.ElapsedMilliseconds -lt 10000) {
            Start-Sleep -Milliseconds 200
            if ($launched.HasExited) { throw "$targetExe exited during startup, after creating its window." }
        }
        if (-not [Win32ShotV5]::IsWindowVisible($hwnd)) {
            Write-Warning 'The app did not show its own window within 10s (set to start minimized?) - showing it from here.'
        }
        Start-Sleep -Milliseconds 2500   # let first frame + data settle
    }
}

if (-not $hwnd) {
    $running = Get-RunningApps
    $seen = if ($running.Count -gt 0) { "Running: $(Format-Apps $running)." } else { 'No copy of the app is running.' }
    if ($targetExe) {
        throw "No main window belongs to $targetExe (still starting, or no window yet). $seen"
    }
    throw "No window of $APP_PROCESS is tagged $MAIN_WINDOW_PROP. Start the app, pass -LaunchExe, or pass -ExpectExe for a build older than the tag. $seen"
}

# Say which instance this is, every time: a capture of the wrong copy looks
# exactly like a capture of the right one.
$owner = Get-WindowProcess $hwnd
$ownerPath = if ($owner -and $owner.Path) { $owner.Path } else { '<unknown path>' }
Write-Host ("Capturing {0} (pid {1})" -f $ownerPath, $owner.Id) -ForegroundColor Gray
Assert-ReleaseBuild $ownerPath

# --- show, place, size -----------------------------------------------------
# Nothing in this section activates the window. SW_SHOW and SW_RESTORE both
# activate as they show, and the SetForegroundWindow that followed took the
# foreground outright, so every capture pulled keyboard focus from whatever
# the user was typing into. PrintWindow needs neither: it renders the window
# whether or not it is in front.
#
# The window may be hidden (resting in the tray) or minimised; both must be
# undone before it will paint anything worth capturing.
$wasHidden = -not [Win32ShotV5]::IsWindowVisible($hwnd)
if ($wasHidden) {
    Write-Host 'Window was hidden (tray) - showing it for the capture.' -ForegroundColor Gray
    [Win32ShotV5]::ShowWindow($hwnd, $SW_SHOWNA) | Out-Null
}
# Maximised is left alone for -NoResize, which shoots the window as it is;
# a move or a size needs the restored window.
$restore = [Win32ShotV5]::IsIconic($hwnd) -or
    ([Win32ShotV5]::IsZoomed($hwnd) -and ($Position -or -not $NoResize))
if ($restore) {
    [Win32ShotV5]::ShowWindow($hwnd, $SW_SHOWNOACTIVATE) | Out-Null
}
if ($Focus) {
    [Win32ShotV5]::SetForegroundWindow($hwnd) | Out-Null
}

# Moved only when asked. Every resize used to MoveWindow it to (80,60) as
# well, which is on the primary monitor: a capture dragged the window there
# from wherever it was, the user's working screen included.
if ($Position) {
    $at = ConvertTo-Point $Position '-Position'
    if ($NoResize) {
        # The window keeps its logical size across the move; measured now.
        $now = New-Object Win32ShotV5+RECT
        [Win32ShotV5]::GetWindowRect($hwnd, [ref]$now) | Out-Null
        $dpiNow = [Win32ShotV5]::GetDpiForWindow($hwnd); if ($dpiNow -le 0) { $dpiNow = 96 }
        Assert-PlacementOnOneMonitor $Position @(@{
            Width  = [int][Math]::Round(($now.Right - $now.Left) * 96.0 / $dpiNow)
            Height = [int][Math]::Round(($now.Bottom - $now.Top) * 96.0 / $dpiNow)
        })
    }
    Write-Host ("Moving to ({0},{1}) physical" -f $at[0], $at[1]) -ForegroundColor Gray
    [Win32ShotV5]::SetWindowPos($hwnd, [IntPtr]::Zero, [int]$at[0], [int]$at[1], 0, 0,
        ($SWP_NOSIZE -bor $SWP_NOZORDER -bor $SWP_NOACTIVATE)) | Out-Null
    # Onto a monitor of another scale, the app takes WM_DPICHANGED and resizes
    # itself first; the DPI below must be the new monitor's.
    Start-Sleep -Milliseconds 400
}

if (-not $NoResize) {
    if (-not $Width -or -not $Height) { throw 'Provide -Width and -Height, or pass -NoResize.' }
    $dpi = [Win32ShotV5]::GetDpiForWindow($hwnd)
    if ($dpi -le 0) { $dpi = 96 }
    $scale = $dpi / 96.0
    $pw = [int][Math]::Round($Width * $scale)
    $ph = [int][Math]::Round($Height * $scale)
    Write-Host ("Resizing to {0}x{1} logical ({2}x{3} physical @ {4} dpi)" -f $Width, $Height, $pw, $ph, $dpi) -ForegroundColor Gray
    # Size only: the top-left stays where it is.
    [Win32ShotV5]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, $pw, $ph,
        ($SWP_NOMOVE -bor $SWP_NOZORDER -bor $SWP_NOACTIVATE)) | Out-Null
}

Start-Sleep -Milliseconds $SettleMs   # let Flutter relayout and repaint

# Before the click too: a click on a hidden view lands on whatever is behind.
Assert-ContentViewVisible $hwnd

if ($ClickAt) {
    $click = ConvertTo-Point $ClickAt '-ClickAt'
    $r0 = New-Object Win32ShotV5+RECT
    [Win32ShotV5]::GetWindowRect($hwnd, [ref]$r0) | Out-Null
    $dpiC = [Win32ShotV5]::GetDpiForWindow($hwnd); if ($dpiC -le 0) { $dpiC = 96 }
    $sc = $dpiC / 96.0
    $cx = $r0.Left + [int]($click[0] * $sc)
    $cy = $r0.Top  + [int]($click[1] * $sc)
}

if ($ClickAt -and -not $RealInput) {
    # Straight to the view, in its client coordinates, as tools/click.ps1
    # posts it: nothing moves the cursor, raises the window or activates it,
    # and a point behind another window still reaches the app. The frame is
    # not Flutter's, so a point outside the view is refused rather than
    # posted where it would mean nothing.
    $view = [Win32ShotV5]::FindChildByClass($hwnd, $VIEW_CLASS)
    $pt = New-Object Win32ShotV5+POINT
    $pt.X = $cx; $pt.Y = $cy
    [Win32ShotV5]::ScreenToClient($view, [ref]$pt) | Out-Null
    $client = New-Object Win32ShotV5+RECT
    [Win32ShotV5]::GetClientRect($view, [ref]$client) | Out-Null
    if ($pt.X -lt 0 -or $pt.Y -lt 0 -or $pt.X -ge $client.Right -or $pt.Y -ge $client.Bottom) {
        throw "-ClickAt '$ClickAt' is on the window's frame, outside the Flutter view. Nothing was clicked or captured."
    }
    Write-Host ("Posting a click at {0},{1} (view client {2},{3})" -f $cx, $cy, $pt.X, $pt.Y) -ForegroundColor Gray
    $WM_MOUSEMOVE = 0x0200; $WM_LBUTTONDOWN = 0x0201; $WM_LBUTTONUP = 0x0202; $MK_LBUTTON = 0x0001
    # Spaced like a hand's click, the move first so the engine has the
    # pointer before it is pressed. The engine then asks to be told when the
    # mouse leaves, which Windows does at once since the real cursor is
    # elsewhere, so no hover is left on whatever was clicked.
    $ok = [Win32ShotV5]::PostMouse($view, $WM_MOUSEMOVE, 0, $pt.X, $pt.Y)
    Start-Sleep -Milliseconds 30
    $ok = $ok -and [Win32ShotV5]::PostMouse($view, $WM_LBUTTONDOWN, $MK_LBUTTON, $pt.X, $pt.Y)
    Start-Sleep -Milliseconds 60
    $ok = $ok -and [Win32ShotV5]::PostMouse($view, $WM_LBUTTONUP, 0, $pt.X, $pt.Y)
    if (-not $ok) { throw 'Posting the click to the app''s view failed. Nothing was captured.' }
    Start-Sleep -Milliseconds 1400   # what the real click's two waits gave the app
}

if ($ClickAt -and $RealInput) {
    Write-Host "Clicking at $cx,$cy (real input)" -ForegroundColor Gray
    # PrintWindow captures an occluded window happily, so a shot can look
    # correct while the app sits BEHIND the terminal - and a synthetic click at
    # screen coordinates then lands on whatever is actually on top. Raise it
    # for the duration of the click (topmost, without activating it), and
    # verify what is under the cursor.
    $HWND_TOPMOST = New-Object IntPtr(-1)
    $SWP_NOMOVE_NOSIZE_NOACTIVATE = $SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_NOACTIVATE
    [Win32ShotV5]::SetWindowPos($hwnd, $HWND_TOPMOST, 0, 0, 0, 0, $SWP_NOMOVE_NOSIZE_NOACTIVATE) | Out-Null
    Start-Sleep -Milliseconds 350

    # Whatever is under the point must belong to the app's own window: its
    # frame or the engine's FLUTTERVIEW child. Anything else - a window on top
    # of it, another copy of the app - would receive the click instead, so
    # it is refused (as click.ps1 refuses) rather than delivered.
    $pt = New-Object Win32ShotV5+POINT
    $pt.X = $cx; $pt.Y = $cy
    $under = [Win32ShotV5]::WindowFromPoint($pt)
    if ([Win32ShotV5]::GetAncestor($under, $GA_ROOT) -ne $hwnd) {
        [Win32ShotV5]::SetWindowPos($hwnd, (New-Object IntPtr(-2)), 0, 0, 0, 0, $SWP_NOMOVE_NOSIZE_NOACTIVATE) | Out-Null
        throw ("Point ($cx,$cy) is covered by a window of pid {0}, not the app's. Nothing was clicked or captured." -f
            [Win32ShotV5]::ProcessIdOf($under))
    }

    # The click moves the user's cursor; it goes back where it was after.
    $cursorBefore = New-Object Win32ShotV5+POINT
    $hadCursor = [Win32ShotV5]::GetCursorPos([ref]$cursorBefore)

    [Win32ShotV5]::ClickAbsolute($cx, $cy)
    Start-Sleep -Milliseconds 900
    # NOTE: topmost is NOT dropped here. Doing so immediately after the click
    # let the window fall behind, and PrintWindow then captured a released
    # compositor surface - a uniformly #B5B5B5 rectangle that looks exactly
    # like a crash. It is restored after the capture instead.
    $script:restoreTopmost = $true

    # Off the window before capturing. Leaving it where it clicked leaves a
    # hover highlight on whatever is under it, which shows up as a
    # real-looking difference when comparing two phases' captures. Where the
    # user had it is off the window unless it was over it; then beside it.
    $overWindow = $hadCursor -and
        $cursorBefore.X -ge $r0.Left -and $cursorBefore.X -lt $r0.Right -and
        $cursorBefore.Y -ge $r0.Top -and $cursorBefore.Y -lt $r0.Bottom
    if ($hadCursor -and -not $overWindow) {
        [Win32ShotV5]::SetCursorPos($cursorBefore.X, $cursorBefore.Y) | Out-Null
    } else {
        [Win32ShotV5]::SetCursorPos($r0.Right + 40, $r0.Top + 4) | Out-Null
    }
    Start-Sleep -Milliseconds 500
}

# --- capture ---------------------------------------------------------------
$rect = New-Object Win32ShotV5+RECT
[Win32ShotV5]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
if ($w -le 0 -or $h -le 0) { throw "Window has no area ($w x $h)." }

# -Out may be absolute. Joined onto the current directory regardless, an
# absolute path became "<cwd>\C:\..." and the save threw after the capture.
$outPath = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path (Get-Location) $Out }

$bmp = New-Object System.Drawing.Bitmap($w, $h)
try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $hdc = $g.GetHdc()
        try {
            # PW_RENDERFULLCONTENT is load-bearing: without it a Flutter window
            # captures as a black rectangle.
            $ok = [Win32ShotV5]::PrintWindow($hwnd, $hdc, $PW_RENDERFULLCONTENT)
            if (-not $ok) { throw 'PrintWindow failed.' }
        } finally { $g.ReleaseHdc($hdc) }
    } finally { $g.Dispose() }

    $dir = Split-Path -Parent $outPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $bmp.Dispose() }

# Guard against the classic silent failure: a uniformly blank capture.
# Sample a grid rather than two points: a large flat background made a
# two-pixel test cry wolf on almost every light-theme capture.
$check = [System.Drawing.Bitmap]::FromFile($outPath)
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
    [Win32ShotV5]::SetWindowPos($hwnd, (New-Object IntPtr(-2)), 0, 0, 0, 0, 0x0002 -bor 0x0001 -bor 0x0010) | Out-Null
}

Write-Host ("Saved {0} ({1}x{2})" -f $Out, $w, $h) -ForegroundColor Green
# The window is no longer raised for a capture, so a covered one is now a
# possible cause; -Focus raises it.
if ($uniform) { Write-Warning 'Capture may be blank - every sampled pixel is the same colour. A uniform grey is a release-build crash (build debug to read it); otherwise check PW_RENDERFULLCONTENT and that the window is not covered, or retry with -Focus.' }
