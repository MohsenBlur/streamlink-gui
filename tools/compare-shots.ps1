<#
.SYNOPSIS
  Compares two captures and distinguishes "moved" from "changed".

.DESCRIPTION
  A naive pixel diff is badly misleading on a dense list: making one control
  4px shorter moves everything below it and reports ~28% of pixels differing,
  which looks exactly like a redesign. Searching for a vertical offset that
  collapses the difference separates the two cases - if some shift takes the
  diff to ~0, the content is identical and only its position moved.

  Two other things this tool learned the hard way:
    * Park the mouse off the window before capturing, or a hover highlight
      shows up as a real difference (shoot.ps1 does this).
    * Ignore a live region if the content genuinely changes between runs
      (viewer counts), via -IgnoreRect.

.EXAMPLE
  ./tools/compare-shots.ps1 -Before shots/phaseD/library.png -After shots/phaseE/library.png
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Before,
    [Parameter(Mandatory = $true)][string]$After,
    [int]$MaxShift = 12,
    [int]$Step = 3,
    # "x,y,w,h" excluded from the comparison, for genuinely live content.
    [string]$IgnoreRect,
    # "x,y,w,h" to compare INSTEAD of the whole image. A shift usually applies
    # to one pane only - shifting the whole frame makes the static chrome (the
    # sidebar, the title bar) mismatch and hides the very result you are
    # looking for.
    [string]$Region
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$a = [System.Drawing.Bitmap]::FromFile((Resolve-Path $Before))
$b = [System.Drawing.Bitmap]::FromFile((Resolve-Path $After))
try {
    if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) {
        Write-Host "Sizes differ: $($a.Width)x$($a.Height) vs $($b.Width)x$($b.Height)" -ForegroundColor Red
        exit 1
    }

    $ig = $null
    if ($IgnoreRect) {
        $p = $IgnoreRect.Split(',')
        $ig = @{ x = [int]$p[0]; y = [int]$p[1]; w = [int]$p[2]; h = [int]$p[3] }
    }

    $rx = 0; $ry = 0; $rw = $a.Width; $rh = $a.Height
    if ($Region) {
        $q = $Region.Split(',')
        $rx = [int]$q[0]; $ry = [int]$q[1]; $rw = [int]$q[2]; $rh = [int]$q[3]
        "region             : ${rx},${ry} ${rw}x${rh}"
    }

    function DiffAt([int]$shift) {
        $d = 0; $t = 0
        $yStart = [Math]::Max($ry, $ry - $shift)
        $yEnd = [Math]::Min($ry + $rh, $a.Height - [Math]::Max(0, $shift))
        for ($y = $yStart; $y -lt $yEnd; $y += $Step) {
            for ($x = $rx; $x -lt ($rx + $rw); $x += $Step) {
                if ($ig -and $x -ge $ig.x -and $x -lt ($ig.x + $ig.w) -and
                    $y -ge $ig.y -and $y -lt ($ig.y + $ig.h)) { continue }
                $t++
                if ($a.GetPixel($x, $y + $shift).ToArgb() -ne $b.GetPixel($x, $y).ToArgb()) { $d++ }
            }
        }
        if ($t -eq 0) { return 0.0 }
        return 100.0 * $d / $t
    }

    $direct = DiffAt 0
    "direct diff        : {0:N2}%" -f $direct

    $best = @{ shift = 0; diff = $direct }
    for ($s = -$MaxShift; $s -le $MaxShift; $s++) {
        if ($s -eq 0) { continue }
        $v = DiffAt $s
        if ($v -lt $best.diff) { $best = @{ shift = $s; diff = $v } }
    }

    if ($best.shift -ne 0) {
        "best shift         : {0}px -> {1:N2}%" -f $best.shift, $best.diff
    }

    if ($best.diff -lt 0.5 -and $best.shift -ne 0) {
        Write-Host ("VERDICT: content identical, moved {0}px vertically." -f $best.shift) -ForegroundColor Green
    } elseif ($direct -lt 0.5) {
        Write-Host 'VERDICT: effectively unchanged.' -ForegroundColor Green
    } elseif ($best.diff -lt 5) {
        Write-Host ("VERDICT: mostly a {0}px shift, with {1:N2}% real change - inspect." -f $best.shift, $best.diff) -ForegroundColor Yellow
    } else {
        Write-Host 'VERDICT: real visual change - look at the capture.' -ForegroundColor Yellow
    }
} finally {
    $a.Dispose(); $b.Dispose()
}
