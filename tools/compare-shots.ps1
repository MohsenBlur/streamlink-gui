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

    # Counting exact mismatches cannot tell "every pixel shifted by 10 units of
    # grey" from "the layout broke" - both report ~100%. Magnitude separates
    # them: a tint change has a small mean delta, a structural change a large
    # one, because structure means text landing where background was.
    function DiffAt([int]$shift) {
        $d = 0; $t = 0; $sumDelta = 0.0; $big = 0
        $yStart = [Math]::Max($ry, $ry - $shift)
        $yEnd = [Math]::Min($ry + $rh, $a.Height - [Math]::Max(0, $shift))
        for ($y = $yStart; $y -lt $yEnd; $y += $Step) {
            for ($x = $rx; $x -lt ($rx + $rw); $x += $Step) {
                if ($ig -and $x -ge $ig.x -and $x -lt ($ig.x + $ig.w) -and
                    $y -ge $ig.y -and $y -lt ($ig.y + $ig.h)) { continue }
                $t++
                $pa = $a.GetPixel($x, $y + $shift)
                $pb = $b.GetPixel($x, $y)
                if ($pa.ToArgb() -ne $pb.ToArgb()) {
                    $d++
                    $delta = [Math]::Abs($pa.R - $pb.R) + [Math]::Abs($pa.G - $pb.G) + [Math]::Abs($pa.B - $pb.B)
                    $sumDelta += $delta
                    if ($delta -gt 90) { $big++ }   # ~30 per channel: a real repaint
                }
            }
        }
        if ($t -eq 0) { return @{ pct = 0.0; meanDelta = 0.0; bigPct = 0.0 } }
        return @{
            pct       = 100.0 * $d / $t
            meanDelta = if ($d -gt 0) { $sumDelta / $d } else { 0.0 }
            bigPct    = 100.0 * $big / $t
        }
    }

    $direct = DiffAt 0
    "pixels differing   : {0:N2}%" -f $direct.pct
    "mean delta         : {0:N1} / 765  (small = a tint shift)" -f $direct.meanDelta
    "substantially diff : {0:N2}%  (large = structure moved)" -f $direct.bigPct

    $best = @{ shift = 0; r = $direct }
    for ($s = -$MaxShift; $s -le $MaxShift; $s++) {
        if ($s -eq 0) { continue }
        $v = DiffAt $s
        if ($v.pct -lt $best.r.pct) { $best = @{ shift = $s; r = $v } }
    }
    if ($best.shift -ne 0 -and $best.r.pct -lt $direct.pct) {
        "best shift         : {0}px -> {1:N2}%" -f $best.shift, $best.r.pct
    }

    if ($best.r.pct -lt 0.5 -and $best.shift -ne 0) {
        Write-Host ("VERDICT: content identical, moved {0}px vertically." -f $best.shift) -ForegroundColor Green
    } elseif ($direct.pct -lt 0.5) {
        Write-Host 'VERDICT: effectively unchanged.' -ForegroundColor Green
    } elseif ($direct.meanDelta -lt 30 -and $direct.bigPct -lt 1.0) {
        # Both conditions matter. A localised layout change touches few pixels
        # (low bigPct) but moves them a lot (high meanDelta); a tint change
        # touches many pixels and moves each of them barely.
        Write-Host ("LIKELY: a uniform tint change - mean delta {0:N1}, only {1:N2}% moved substantially. Still worth a glance." -f $direct.meanDelta, $direct.bigPct) -ForegroundColor Green
    } elseif ($best.r.pct -lt 5) {
        Write-Host ("VERDICT: mostly a {0}px shift, with {1:N2}% real change - inspect." -f $best.shift, $best.r.pct) -ForegroundColor Yellow
    } else {
        Write-Host ("LIKELY: a real visual change - mean delta {0:N1}, {1:N2}% moved substantially." -f $direct.meanDelta, $direct.bigPct) -ForegroundColor Yellow
    }

    Write-Host 'These numbers narrow down WHERE to look; they do not decide whether it is correct.' -ForegroundColor DarkGray
} finally {
    $a.Dispose(); $b.Dispose()
}
