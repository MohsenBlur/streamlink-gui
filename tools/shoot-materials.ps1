<#
.SYNOPSIS
  Captures every material x theme combination of the dev build to a folder.

.DESCRIPTION
  Cycles the release build's local config through each registered material and
  brightness, relaunching and shooting 1600x1000 each time. The comparison the
  material work lives or dies by is side-by-side shots taken minutes apart on
  the same display - this makes that a one-liner.

  Config is isolated exactly as in shoot-matrix.ps1 (shoot-common.ps1): the
  build reads a staged copy beside itself, never the user's real settings.
  Without that, the material written into the staged file was never read and
  every shot showed whatever material %APPDATA% held.

  -Position and -Focus mean what they do in shoot-matrix.ps1: where the
  window opens and is shot, and whether captures take the foreground (by
  default they do not).

.EXAMPLE
  ./tools/shoot-materials.ps1 -OutDir shots/baseline-v18

.EXAMPLE
  # Off the primary; why -2400 and not the monitor's own -2160 is in
  # shoot-matrix.ps1's example.
  ./tools/shoot-materials.ps1 -OutDir shots/baseline-v18 -Position '-2400,-813'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string[]]$Materials = @('rack', 'analogue', 'deck'),
    [int]$Width = 1600,
    [int]$Height = 1000,
    # "x,y", physical virtual-desktop pixels (see shoot-matrix.ps1).
    [string]$Position,
    [switch]$Focus
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'shoot-common.ps1')

$root = Split-Path $PSScriptRoot -Parent
$exe = Resolve-ShootExe 'build\windows\x64\runner\Release\streamlink_gui.exe' $root

New-Item -ItemType Directory -Force (Join-Path $root $OutDir) | Out-Null

$placeArgs = @{}
if ($Position) { $placeArgs.Position = $Position }
if ($Focus) { $placeArgs.Focus = $true }

foreach ($m in $Materials) {
    foreach ($dark in @($true, $false)) {
        $theme = if ($dark) { 'dark' } else { 'light' }
        Stop-AppAt $exe
        $settings = @{
            material        = $m
            is_dark_theme   = $dark
            # A copied config that starts minimized would rest in the tray,
            # and shoot.ps1 waits for the app to show its own window.
            start_minimized = $false
        }
        if ($Position) {
            $placement = Get-PlacementSettings $Position
            foreach ($key in $placement.Keys) { $settings[$key] = $placement[$key] }
        }
        Set-IsolatedConfig $exe $settings
        # shoot.ps1 launches it, so the capture is refused - not quietly taken
        # of the installed app - when another copy holds the single-instance
        # mutex. The long settle replaces the old fixed 10s wait: material
        # textures and the shader warm up after the first frame.
        & (Join-Path $PSScriptRoot "shoot.ps1") -Out "$OutDir/${m}_${theme}.png" -Width $Width -Height $Height -LaunchExe $exe -SettleMs 7500 @placeArgs
    }
}
Stop-AppAt $exe
Write-Output "captured $($Materials.Count * 2) shots to $OutDir"
