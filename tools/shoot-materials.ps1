<#
.SYNOPSIS
  Captures every material x theme combination of the dev build to a folder.

.DESCRIPTION
  Cycles the release build's local config through each registered material and
  brightness, relaunching and shooting 1600x1000 each time. The comparison the
  material work lives or dies by is side-by-side shots taken minutes apart on
  the same display - this makes that a one-liner.

.EXAMPLE
  ./tools/shoot-materials.ps1 -OutDir shots/baseline-v18
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string[]]$Materials = @('rack', 'analogue', 'deck'),
    [int]$Width = 1600,
    [int]$Height = 1000
)

$root = Split-Path $PSScriptRoot -Parent
$rel = Join-Path $root "build\windows\x64\runner\Release"
$exe = Join-Path $rel "streamlink_gui.exe"
$cfg = Join-Path $rel "channels_config.json"
if (-not (Test-Path $exe)) { throw "release build not found - flutter build windows --release first" }

New-Item -ItemType Directory -Force (Join-Path $root $OutDir) | Out-Null

foreach ($m in $Materials) {
    foreach ($dark in @($true, $false)) {
        $theme = if ($dark) { 'dark' } else { 'light' }
        Get-Process streamlink_gui -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep 2
        $py = "import io,json`n" +
              "p = r'$cfg'`n" +
              "d = json.loads(io.open(p, encoding='utf-8-sig').read())`n" +
              "d['settings']['material'] = '$m'`n" +
              "d['settings']['is_dark_theme'] = $(if ($dark) {'True'} else {'False'})`n" +
              "io.open(p,'w',encoding='utf-8',newline='').write(json.dumps(d, indent=2))"
        python -c $py
        Start-Process $exe
        Start-Sleep 10
        & (Join-Path $PSScriptRoot "shoot.ps1") -Out "$OutDir/${m}_${theme}.png" -Width $Width -Height $Height
    }
}
Get-Process streamlink_gui -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Output "captured $($Materials.Count * 2) shots to $OutDir"
