<#
.SYNOPSIS
  Clicks a point inside the app window, for scripted UI-state screenshots.

.DESCRIPTION
  The screenshot matrix needs states no launch flag can reach - an open
  dialog, a picked tab. This finds the Flutter window, brings it forward,
  and synthesizes one left click at the given CLIENT coordinates. Logical
  pixels at 96dpi equal physical; on scaled displays pass physical.

.EXAMPLE
  ./tools/click.ps1 -X 417 -Y 662
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$X,
    [Parameter(Mandatory = $true)][int]$Y
)

$src = @'
using System;
using System.Runtime.InteropServices;
public class ClickPoke {
  [DllImport("user32.dll")] public static extern IntPtr FindWindowA(string cls, string win);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, int e);
}
'@
Add-Type -TypeDefinition $src

# The process's own main-window handle, not FindWindow: the app also owns a
# FLUTTER_RUNNER_WIN32_WINDOW_TRAY window, and FindWindow's pick between the
# two is undefined - the same trap shoot.ps1 documents.
$proc = Get-Process streamlink_gui -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($null -eq $proc) { throw "app window not found" }
$h = [IntPtr]$proc.MainWindowHandle
$r = New-Object ClickPoke+RECT
[ClickPoke]::GetWindowRect($h, [ref]$r) | Out-Null
[ClickPoke]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 600
[ClickPoke]::SetCursorPos($r.L + $X, $r.T + $Y) | Out-Null
Start-Sleep -Milliseconds 250
[ClickPoke]::mouse_event(2, 0, 0, 0, 0)   # LEFTDOWN
Start-Sleep -Milliseconds 60
[ClickPoke]::mouse_event(4, 0, 0, 0, 0)   # LEFTUP
Write-Output "clicked ($X, $Y) in window at ($($r.L), $($r.T))"
