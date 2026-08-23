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

.EXAMPLE
  ./tools/shoot.ps1 -Out shots/baseline/home_1600x1000.png -Width 1600 -Height 1000

.EXAMPLE
  # Capture whatever is on screen right now, without touching the window.
  ./tools/shoot.ps1 -Out shots/current.png -NoResize
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$Width,
    [int]$Height,
    [switch]$NoResize,
    [string]$LaunchExe,
    [int]$SettleMs = 900,
    [int]$LaunchTimeoutMs = 30000
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

if (-not ([System.Management.Automation.PSTypeName]'Win32Shot').Type) {
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Win32Shot {
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
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    // Enumerate rather than FindWindow: the app also owns a
    // FLUTTER_RUNNER_WIN32_WINDOW_TRAY window, and the main window is HIDDEN
    // (not merely minimised) whenever the app is resting in the tray - which
    // is its normal state. Enumeration finds it in that state; we restore it
    // afterwards.
    public static IntPtr FindMainWindow(string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            var sb = new StringBuilder(256);
            GetClassNameW(h, sb, 256);
            if (sb.ToString() == cls) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
}

$WINDOW_CLASS = 'FLUTTER_RUNNER_WIN32_WINDOW'
$SW_RESTORE = 9
$SW_SHOW = 5
$PW_RENDERFULLCONTENT = 2

function Find-AppWindow {
    $h = [Win32Shot]::FindMainWindow($WINDOW_CLASS)
    if ($h -eq [IntPtr]::Zero) { return $null }
    return $h
}

# --- locate, launching if asked -------------------------------------------
$hwnd = Find-AppWindow

if (-not $hwnd -and $LaunchExe) {
    if (-not (Test-Path $LaunchExe)) { throw "LaunchExe not found: $LaunchExe" }
    Write-Host "Launching $LaunchExe ..." -ForegroundColor Gray
    Start-Process -FilePath (Resolve-Path $LaunchExe)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $hwnd -and $sw.ElapsedMilliseconds -lt $LaunchTimeoutMs) {
        Start-Sleep -Milliseconds 300
        $hwnd = Find-AppWindow
    }
    if ($hwnd) { Start-Sleep -Milliseconds 2500 }   # let first frame + data settle
}

if (-not $hwnd) {
    throw "No visible '$WINDOW_CLASS' window. Start the app, or pass -LaunchExe. (Note: a single-instance mutex means a second launch only focuses the existing window.)"
}

# --- size ------------------------------------------------------------------
# The window may be hidden (resting in the tray) or minimised; both must be
# undone before it will paint anything worth capturing.
$wasHidden = -not [Win32Shot]::IsWindowVisible($hwnd)
if ($wasHidden) {
    Write-Host 'Window was hidden (tray) - showing it for the capture.' -ForegroundColor Gray
    [Win32Shot]::ShowWindow($hwnd, $SW_SHOW) | Out-Null
}
[Win32Shot]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
[Win32Shot]::SetForegroundWindow($hwnd) | Out-Null

if (-not $NoResize) {
    if (-not $Width -or -not $Height) { throw 'Provide -Width and -Height, or pass -NoResize.' }
    $dpi = [Win32Shot]::GetDpiForWindow($hwnd)
    if ($dpi -le 0) { $dpi = 96 }
    $scale = $dpi / 96.0
    $pw = [int][Math]::Round($Width * $scale)
    $ph = [int][Math]::Round($Height * $scale)
    Write-Host ("Resizing to {0}x{1} logical ({2}x{3} physical @ {4} dpi)" -f $Width, $Height, $pw, $ph, $dpi) -ForegroundColor Gray
    [Win32Shot]::MoveWindow($hwnd, 80, 60, $pw, $ph, $true) | Out-Null
}

Start-Sleep -Milliseconds $SettleMs   # let Flutter relayout and repaint

# --- capture ---------------------------------------------------------------
$rect = New-Object Win32Shot+RECT
[Win32Shot]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
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
            $ok = [Win32Shot]::PrintWindow($hwnd, $hdc, $PW_RENDERFULLCONTENT)
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

Write-Host ("Saved {0} ({1}x{2})" -f $Out, $w, $h) -ForegroundColor Green
if ($uniform) { Write-Warning 'Capture may be blank - two sampled pixels are identical. Check PW_RENDERFULLCONTENT and that the window is not occluded.' }
