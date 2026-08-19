# fetch-deps.ps1
# Downloads, verifies and assembles the bundled runtime under bin/.
#
# The executables in bin/ are intentionally NOT committed to git (see .gitignore).
# bin/deps_manifest.json is the single source of truth for what gets fetched.
# The release workflow runs this before packaging; developers can run it directly
# to rebuild bin/ locally:
#
#   powershell -ExecutionPolicy Bypass -File tools/fetch-deps.ps1
#
# Downloads are cached in .deps-cache/ and re-verified by hash, so re-runs are cheap.

[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$CacheDir,
    [string]$DestRoot,
    [switch]$Force,
    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Invoke-WebRequest is ~10x faster without the progress UI

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $RepoRoot "bin\deps_manifest.json" }
if (-not $CacheDir)     { $CacheDir     = Join-Path $RepoRoot ".deps-cache" }
if (-not $DestRoot)     { $DestRoot     = $RepoRoot }
if (-not (Test-Path $DestRoot)) { New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null }

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-Step($msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    $msg" -ForegroundColor Green }
function Write-Info($msg)  { Write-Host "    $msg" -ForegroundColor Gray }

if (-not (Test-Path $ManifestPath)) {
    throw "Manifest not found: $ManifestPath"
}

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }

function Get-Sha256($path) {
    return (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Resolve-Artifact($name, $component) {
    # Returns a path to a hash-verified local copy of the component's artifact.
    $fileName = "$name-$($component.version)-" + [System.IO.Path]::GetFileName(([uri]$component.url).AbsolutePath)
    $cachePath = Join-Path $CacheDir $fileName
    $expected = $component.sha256.ToLowerInvariant()

    if ((Test-Path $cachePath) -and -not $Force) {
        $actual = Get-Sha256 $cachePath
        if ($actual -eq $expected) {
            Write-Info "cached  $fileName"
            return $cachePath
        }
        Write-Info "cache miss (hash differs), re-downloading"
        Remove-Item $cachePath -Force
    }

    Write-Info "download $($component.url)"
    try {
        Invoke-WebRequest -Uri $component.url -OutFile $cachePath -UseBasicParsing
    } catch {
        throw "Failed to download $name from $($component.url): $_"
    }

    $actual = Get-Sha256 $cachePath
    if ($actual -ne $expected) {
        Remove-Item $cachePath -Force -ErrorAction SilentlyContinue
        throw @"
SHA-256 mismatch for '$name'.
  expected: $expected
  actual:   $actual
The upstream asset changed or the download was corrupted. If upstream legitimately
republished this version, update bin/deps_manifest.json deliberately - do not just
paste the new hash without checking what changed.
"@
    }

    if ($component.size) {
        $actualSize = (Get-Item $cachePath).Length
        if ($actualSize -ne $component.size) {
            throw "Size mismatch for '$name': expected $($component.size) bytes, got $actualSize"
        }
    }

    Write-Ok "verified $fileName"
    return $cachePath
}

function Install-Component($name, $component) {
    Write-Step "$name $($component.version)"
    $artifact = Resolve-Artifact $name $component

    if ($component.type -eq "file") {
        $dest = Join-Path $DestRoot $component.dest
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item $artifact $dest -Force
        Write-Ok "installed $($component.dest)"
        return
    }

    if ($component.type -ne "zip") {
        throw "Unsupported component type '$($component.type)' for '$name'"
    }

    # Extract to a scratch dir, then copy only the paths the manifest maps.
    # Anything not listed in 'map' is deliberately not shipped.
    $scratch = Join-Path $CacheDir ("extract-" + $name)
    if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force }
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($artifact, $scratch)

    $srcRoot = $scratch
    if ($component.stripPrefix) {
        $srcRoot = Join-Path $scratch $component.stripPrefix
        if (-not (Test-Path $srcRoot)) {
            throw "stripPrefix '$($component.stripPrefix)' not found inside $name archive"
        }
    }

    $destRoot = Join-Path $DestRoot $component.dest
    if (-not (Test-Path $destRoot)) { New-Item -ItemType Directory -Path $destRoot -Force | Out-Null }

    foreach ($entry in $component.map) {
        $src = Join-Path $srcRoot $entry.from
        $dst = Join-Path $destRoot $entry.to
        if (-not (Test-Path $src)) {
            throw "'$name' archive is missing expected path '$($entry.from)' - the upstream layout changed"
        }
        if (Test-Path $src -PathType Container) {
            if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
            Copy-Item $src $dst -Recurse -Force
        } else {
            $dstDir = Split-Path -Parent $dst
            if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item $src $dst -Force
        }
        Write-Ok "installed $($component.dest)/$($entry.to)"
    }

    Remove-Item $scratch -Recurse -Force
}

Write-Host "Assembling bundled runtime into bin/" -ForegroundColor Yellow
Write-Info "manifest: $ManifestPath"
Write-Info "cache:    $CacheDir"
Write-Host ""

foreach ($prop in $manifest.components.PSObject.Properties) {
    Install-Component $prop.Name $prop.Value
}

Write-Host ""
if ($SkipVerify) {
    Write-Step "Done (verification skipped)."
} else {
    Write-Step "Done. Verifying the assembled bin/ ..."
    & (Join-Path $PSScriptRoot "verify-bundle.ps1") -Root $DestRoot -BinOnly
}
