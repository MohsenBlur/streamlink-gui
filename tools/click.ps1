<#
.SYNOPSIS
  Clicks a point inside ONE copy of the app's window, for scripted UI-state
  screenshots.

.DESCRIPTION
  The screenshot matrix needs states no launch flag can reach - an open
  dialog, a picked tab. This finds the main window of the copy you name and
  delivers one left click at the given point.

  By default the click is POSTED: a mouse move, button down and button up
  go straight to the engine's FLUTTERVIEW window, in its own client
  coordinates. The user's cursor does not move, and the app is neither
  activated nor raised, so a scripted click does not take focus from
  whatever the user is typing into - the reason this no longer calls
  SetForegroundWindow. Flutter's Windows embedder reads pointer input from
  those window messages, so a posted click is a click to it, and one whose
  point is behind another window still reaches the app. -RealInput
  synthesizes a real click instead (SendInput): it moves the cursor, put
  back afterwards, activates the app as any click does, and is refused when
  the point is covered by another window - with nothing raising the app
  first any more, bring it forward yourself (shoot.ps1 -Focus) if it is not
  on top.

  WHICH copy is the whole point. The installed app usually rests in the
  tray while a build is under test, both executables are streamlink_gui.exe,
  and "the first streamlink_gui process with a main window" was whichever
  one Windows listed first - so a scripted click could land in the user's
  own instance. The target is now named explicitly, by -ExePath or
  -ProcessId, and its window is the one the runner marks as the main window
  (the TwitchStreamlinkGUI.MainWindow property, windows/runner/
  single_instance.cpp): not the tray's message window, and never a window
  of another process. A click whose point is covered by someone else's
  window is refused rather than delivered to it.

  -X and -Y are LOGICAL pixels from the window's top-left, scaled by the
  window's own DPI - the same contract as shoot.ps1 -ClickAt. The script runs
  per-monitor DPI aware, so the window rect and the cursor are both in
  physical pixels on every monitor; a DPI-unaware host saw the 150% monitor
  through a virtualized, scaled-down coordinate space.

.EXAMPLE
  ./tools/click.ps1 -ExePath build/windows/x64/runner/Release/streamlink_gui.exe -X 417 -Y 662

.EXAMPLE
  ./tools/click.ps1 -ProcessId 12345 -X 40 -Y 20

.EXAMPLE
  # Resolve the window and the point, and say where the click would go,
  # without delivering it.
  ./tools/click.ps1 -ProcessId 12345 -X 40 -Y 20 -WhatIf
#>
[CmdletBinding(DefaultParameterSetName = 'ByPath', SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'ByPath')][string]$ExePath,
    [Parameter(Mandatory = $true, ParameterSetName = 'ById')][int]$ProcessId,
    [Parameter(Mandatory = $true)][double]$X,
    [Parameter(Mandatory = $true)][double]$Y,
    # A real, synthesized click (SendInput) rather than a posted one; see
    # .DESCRIPTION.
    [switch]$RealInput
)

$ErrorActionPreference = 'Stop'

# Versioned type name: Add-Type cannot redefine a type in a session that
# already loaded an older copy (see shoot.ps1).
if (-not ([System.Management.Automation.PSTypeName]'ClickPokeV3').Type) {
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class ClickPokeV3 {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetPropW(IntPtr h, string name);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);

    // The engine's render surface, a direct child of the runner window. A
    // real null title: PowerShell would pass $null as "" (see shoot.ps1).
    public static IntPtr ViewOf(IntPtr main) {
        return FindWindowExW(main, IntPtr.Zero, "FLUTTERVIEW", null);
    }

    // One posted mouse message, client coordinates packed as a real one's.
    public static bool PostMouse(IntPtr view, uint msg, uint keys, int x, int y) {
        IntPtr lp = new IntPtr((y << 16) | (x & 0xFFFF));
        return PostMessageW(view, msg, new IntPtr(keys), lp);
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public MOUSEINPUT mi; }

    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, for this thread: rects,
    // cursor positions and the virtual-desktop metrics below all become
    // physical pixels. Returns false when the call is unavailable.
    public static bool PerMonitorAware() {
        return SetThreadDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero;
    }

    // Top-level windows of `pid` that carry the runner's main-window tag.
    public static IntPtr[] TaggedWindowsOf(uint pid) {
        var found = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint owner;
            GetWindowThreadProcessId(h, out owner);
            if (owner == pid && GetPropW(h, "TwitchStreamlinkGUI.MainWindow") != IntPtr.Zero) found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    public static uint ProcessIdOf(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); return pid; }

    // mouse_event is legacy and Flutter's Win32 input path did not observe
    // it (shoot.ps1); SendInput with absolute virtual-desktop coordinates.
    public static void ClickAbsolute(int x, int y) {
        int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77);
        int vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
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
}
'@
}

if (-not [ClickPokeV3]::PerMonitorAware()) {
    Write-Warning 'Could not make this thread per-monitor DPI aware; on a scaled monitor the click may land off target.'
}

# --- the one process ------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'ByPath') {
    if (-not (Test-Path $ExePath)) { throw "Exe not found: $ExePath" }
    $full = (Resolve-Path $ExePath).ProviderPath
    # -eq on strings is case-insensitive, as Windows paths are.
    $procs = @(Get-Process streamlink_gui -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $full })
    if ($procs.Count -eq 0) { throw "No running copy of $full." }
    $label = $full
} else {
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $p) { throw "No process with id $ProcessId." }
    $procs = @($p)
    $label = "pid $ProcessId"
}

$windows = @()
foreach ($p in $procs) { $windows += [ClickPokeV3]::TaggedWindowsOf([uint32]$p.Id) }
if ($windows.Count -eq 0) {
    throw ("$label has no window tagged TwitchStreamlinkGUI.MainWindow - still starting, " +
        "or a build older than the tag. Nothing was clicked.")
}
if ($windows.Count -gt 1) {
    throw "$label has $($windows.Count) tagged main windows; refusing to guess which one to click."
}
$h = [IntPtr]$windows[0]
$ownerPid = [ClickPokeV3]::ProcessIdOf($h)

if (-not [ClickPokeV3]::IsWindowVisible($h) -or [ClickPokeV3]::IsIconic($h)) {
    throw "$label's window is hidden or minimized (resting in the tray?). Show it first; nothing was clicked."
}

# --- the point --------------------------------------------------------------
$r = New-Object ClickPokeV3+RECT
[ClickPokeV3]::GetWindowRect($h, [ref]$r) | Out-Null
$dpi = [ClickPokeV3]::GetDpiForWindow($h)
if ($dpi -le 0) { $dpi = 96 }
$scale = $dpi / 96.0
$cx = $r.L + [int][Math]::Round($X * $scale)
$cy = $r.T + [int][Math]::Round($Y * $scale)
if ($cx -lt $r.L -or $cx -ge $r.R -or $cy -lt $r.T -or $cy -ge $r.B) {
    throw ("({0}, {1}) logical is outside the window ({2}x{3} physical @ {4} dpi)." -f
        $X, $Y, ($r.R - $r.L), ($r.B - $r.T), $dpi)
}

$how = if ($RealInput) { 'Left-click (real input)' } else { 'Left-click (posted)' }
$what = "pid $ownerPid at ($cx, $cy) physical, from ($X, $Y) logical @ $dpi dpi"
if (-not $PSCmdlet.ShouldProcess($what, $how)) { return }

if (-not $RealInput) {
    # Straight to the view, in its client coordinates. The window's frame is
    # not Flutter's, so a point outside the view is refused rather than
    # posted where it would mean nothing.
    $view = [ClickPokeV3]::ViewOf($h)
    if ($view -eq [IntPtr]::Zero -or -not [ClickPokeV3]::IsWindowVisible($view)) {
        throw "$label's window has no visible FLUTTERVIEW (the invisible-window bug, audit C1?). Nothing was clicked."
    }
    $pt = New-Object ClickPokeV3+POINT
    $pt.X = $cx; $pt.Y = $cy
    [ClickPokeV3]::ScreenToClient($view, [ref]$pt) | Out-Null
    $client = New-Object ClickPokeV3+RECT
    [ClickPokeV3]::GetClientRect($view, [ref]$client) | Out-Null
    if ($pt.X -lt 0 -or $pt.Y -lt 0 -or $pt.X -ge $client.R -or $pt.Y -ge $client.B) {
        throw ("({0}, {1}) logical is on the window's frame, outside the Flutter view. Nothing was clicked." -f $X, $Y)
    }
    $WM_MOUSEMOVE = 0x0200; $WM_LBUTTONDOWN = 0x0201; $WM_LBUTTONUP = 0x0202; $MK_LBUTTON = 0x0001
    # Spaced like a hand's click, the move first so the engine has the
    # pointer before it is pressed. The engine then asks to be told when the
    # mouse leaves, which Windows does at once since the real cursor is
    # elsewhere, so no hover is left on whatever was clicked.
    $ok = [ClickPokeV3]::PostMouse($view, $WM_MOUSEMOVE, 0, $pt.X, $pt.Y)
    Start-Sleep -Milliseconds 30
    $ok = $ok -and [ClickPokeV3]::PostMouse($view, $WM_LBUTTONDOWN, $MK_LBUTTON, $pt.X, $pt.Y)
    Start-Sleep -Milliseconds 60
    $ok = $ok -and [ClickPokeV3]::PostMouse($view, $WM_LBUTTONUP, 0, $pt.X, $pt.Y)
    if (-not $ok) { throw "Posting the click to $label's view failed." }
    Write-Output ("posted a click at ({0}, {1}) logical = ({2}, {3}) in the view of pid {4}, window at ({5}, {6}) @ {7} dpi" -f
        $X, $Y, $pt.X, $pt.Y, $ownerPid, $r.L, $r.T, $dpi)
    return
}

# Whatever is under the point must belong to the target: its own frame or the
# engine's FLUTTERVIEW child. Anything else - a terminal on top, the other
# copy's window - would receive the click instead. Nothing raises the app
# first: SetForegroundWindow took the focus from the user's own window.
$pt = New-Object ClickPokeV3+POINT
$pt.X = $cx; $pt.Y = $cy
$under = [ClickPokeV3]::WindowFromPoint($pt)
$GA_ROOT = 2
$underRoot = [ClickPokeV3]::GetAncestor($under, $GA_ROOT)
if ($underRoot -ne $h -or [ClickPokeV3]::ProcessIdOf($under) -ne $ownerPid) {
    # Parenthesised: -f binds tighter than +, and would format only the last part.
    throw (("Point ($cx, $cy) is covered by a window of pid {0}, not {1}'s. Nothing was clicked. " +
        "Bring it forward first (shoot.ps1 -Focus), or leave out -RealInput to post the click.") -f
        [ClickPokeV3]::ProcessIdOf($under), $label)
}

# A real click moves the user's cursor; it goes back where it was after.
$cursorBefore = New-Object ClickPokeV3+POINT
$hadCursor = [ClickPokeV3]::GetCursorPos([ref]$cursorBefore)
[ClickPokeV3]::ClickAbsolute($cx, $cy)
if ($hadCursor) {
    Start-Sleep -Milliseconds 100
    [ClickPokeV3]::SetCursorPos($cursorBefore.X, $cursorBefore.Y) | Out-Null
}
Write-Output ("clicked ({0}, {1}) logical = ({2}, {3}) physical in pid {4} at ({5}, {6}) @ {7} dpi" -f
    $X, $Y, $cx, $cy, $ownerPid, $r.L, $r.T, $dpi)
