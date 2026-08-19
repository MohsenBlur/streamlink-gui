# verify-bundle.ps1
# Asserts that an assembled bundle (a directory or a packaged zip) actually contains
# the runtime this app needs.
#
# This is the gate that would have caught the defect where 18 consecutive releases
# shipped a bin/ directory containing the Python standard library but no interpreter,
# no streamlink, no ffmpeg and no yt-dlp - so every stream and every download failed
# on a fresh install.
#
#   tools/verify-bundle.ps1 -Root .                      # verify the working tree's bin/
#   tools/verify-bundle.ps1 -Root build/.../Release      # verify a staged release dir
#   tools/verify-bundle.ps1 -Zip out.zip -Prefix name    # verify a packaged zip

[CmdletBinding(DefaultParameterSetName = "Dir")]
param(
    [Parameter(ParameterSetName = "Dir")]
    [string]$Root,

    [Parameter(ParameterSetName = "Zip", Mandatory = $true)]
    [string]$Zip,

    [Parameter(ParameterSetName = "Zip")]
    [string]$Prefix = "",

    [Parameter(ParameterSetName = "Dir")]
    [switch]$BinOnly,

    [string]$ManifestPath
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $RepoRoot "bin\deps_manifest.json" }

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$requirements = $manifest.bundleRequirements

if ($BinOnly) {
    $requirements = $requirements | Where-Object { $_.path -like "bin/*" }
}

$failures = New-Object System.Collections.Generic.List[string]
$checked = 0

if ($PSCmdlet.ParameterSetName -eq "Zip") {
    if (-not (Test-Path $Zip)) { throw "Zip not found: $Zip" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Zip))
    try {
        # Index entries by normalised relative path.
        $entries = @{}
        foreach ($e in $archive.Entries) {
            $key = $e.FullName -replace '\\', '/'
            if ($Prefix) {
                $p = ($Prefix -replace '\\', '/').TrimEnd('/') + '/'
                if ($key.StartsWith($p)) { $key = $key.Substring($p.Length) } else { continue }
            }
            $entries[$key] = $e.Length
        }
        foreach ($req in $requirements) {
            $checked++
            $key = $req.path -replace '\\', '/'
            if (-not $entries.ContainsKey($key)) {
                $failures.Add("MISSING  $($req.path)")
            } elseif ($entries[$key] -lt $req.minBytes) {
                $failures.Add("TOO SMALL $($req.path) - $($entries[$key]) bytes, expected >= $($req.minBytes)")
            }
        }
        $totalBytes = ($archive.Entries | Measure-Object -Property Length -Sum).Sum
        $target = "zip '$Zip'"
    } finally {
        $archive.Dispose()
    }
} else {
    if (-not $Root) { $Root = $RepoRoot }
    if (-not (Test-Path $Root)) { throw "Root not found: $Root" }
    foreach ($req in $requirements) {
        $checked++
        $full = Join-Path $Root ($req.path -replace '/', '\')
        if (-not (Test-Path $full -PathType Leaf)) {
            $failures.Add("MISSING  $($req.path)")
        } else {
            $len = (Get-Item $full).Length
            if ($len -lt $req.minBytes) {
                $failures.Add("TOO SMALL $($req.path) - $len bytes, expected >= $($req.minBytes)")
            }
        }
    }
    $totalBytes = 0
    $target = "directory '$Root'"
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Bundle verification FAILED for $target" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $f" -ForegroundColor Red }
    Write-Host ""
    Write-Host "The bundled runtime is incomplete. Do NOT publish this artifact:" -ForegroundColor Yellow
    Write-Host "users would get an app that cannot play streams or download VODs." -ForegroundColor Yellow
    Write-Host "Run 'tools/fetch-deps.ps1' to assemble bin/ before packaging." -ForegroundColor Yellow
    exit 1
}

Write-Host "Bundle verification passed for $target ($checked required paths present)" -ForegroundColor Green
if ($totalBytes -gt 0) {
    Write-Host ("Uncompressed size: {0:N1} MB" -f ($totalBytes / 1MB)) -ForegroundColor Gray
}
exit 0
