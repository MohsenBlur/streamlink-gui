<#
Builds the runner's MPC-HC /slave receiver (windows/runner/mpc_slave.cpp) into
its unit tests and into the probe, with the runner's own compiler flags, and
runs the unit tests.

    powershell -NoProfile -File tool\mpc_slave_probe\build.ps1 [-Out <dir>] [-NoTest]

The flags are windows/CMakeLists.txt's APPLY_STANDARD_SETTINGS (/W4 /WX
/wd4100 /EHsc _HAS_EXCEPTIONS=0, C++17) plus the runner's NOMINMAX and CMake's
Windows defaults, so a warning here is a warning that breaks the app's build.
MSVC is found with vswhere; nothing is installed or changed.
#>
param(
  [string]$Out = (Join-Path $env:TEMP 'mpc_slave_probe'),
  [switch]$NoTest
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$runner = Resolve-Path (Join-Path $here '..\..\windows\runner')

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'vswhere.exe not found: install the Visual Studio C++ tools.' }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'No Visual Studio with the C++ x64 tools.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'

New-Item -ItemType Directory -Force $Out | Out-Null
$flags = '/nologo /std:c++17 /W4 /WX /wd4100 /EHsc /D_HAS_EXCEPTIONS=0 /DNOMINMAX /DUNICODE /D_UNICODE /DWIN32 /D_WINDOWS /O2'
foreach ($target in @('mpc_slave_test', 'mpc_slave_probe')) {
  # Through a batch file: Windows PowerShell does not escape the quotes in a
  # native command's arguments, and every path here can hold a space.
  $bat = Join-Path $Out "build_$target.bat"
  @(
    '@echo off'
    "call `"$vcvars`" >nul || exit /b 1"
    "cd /d `"$Out`""
    "cl $flags /I `"$runner`" `"$here\$target.cpp`" `"$runner\mpc_slave.cpp`" /Fe:$target.exe /link user32.lib"
  ) | Set-Content -Path $bat -Encoding ascii
  & cmd.exe /d /c $bat
  if ($LASTEXITCODE -ne 0) { throw "$target did not build" }
}

if (-not $NoTest) {
  & (Join-Path $Out 'mpc_slave_test.exe')
  if ($LASTEXITCODE -ne 0) { throw 'mpc_slave_test failed' }
}
