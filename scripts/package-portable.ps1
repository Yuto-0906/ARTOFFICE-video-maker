[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$SkipFetch,
    [string]$ApplicationPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$package = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "package.json") | ConvertFrom-Json
$version = [string]$package.version
$vendorTools = Join-Path $repoRoot "vendor-tools"

if (-not $SkipFetch) {
    & (Join-Path $PSScriptRoot "fetch-tools.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "Runtime tool preparation failed."
    }
}

if (-not $SkipBuild) {
    Push-Location $repoRoot
    try {
        & npm.cmd run tauri -- build --no-bundle
        if ($LASTEXITCODE -ne 0) {
            throw "The Tauri release build failed."
        }
    } finally {
        Pop-Location
    }
}

$application = if ([string]::IsNullOrWhiteSpace($ApplicationPath)) {
    Join-Path $repoRoot "src-tauri\target\release\artoffice-video-maker.exe"
} else {
    (Resolve-Path -LiteralPath $ApplicationPath).Path
}
foreach ($required in @(
    $application,
    (Join-Path $vendorTools "ffmpeg\bin\ffmpeg.exe"),
    (Join-Path $vendorTools "ffmpeg\bin\ffprobe.exe"),
    (Join-Path $vendorTools "imagemagick\magick.exe"),
    (Join-Path $vendorTools "resources\fonts\NotoSansJP-Black.ttf")
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "A required distribution file is missing: $required"
    }
}

$artifactsRoot = Join-Path $repoRoot "artifacts"
$folderName = "ARTOFFICE-video-maker-v$version-windows-x64"
$staging = Join-Path $artifactsRoot $folderName
$zipPath = Join-Path $artifactsRoot "$folderName.zip"
$checksumPath = "$zipPath.sha256"
New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null

if (Test-Path -LiteralPath $staging) {
    $resolvedStaging = (Resolve-Path -LiteralPath $staging).Path
    $artifactsPrefix = [IO.Path]::GetFullPath($artifactsRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedStaging.StartsWith($artifactsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a directory outside artifacts: $resolvedStaging"
    }
    Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
}
foreach ($oldFile in @($zipPath,$checksumPath)) {
    if (Test-Path -LiteralPath $oldFile) {
        Remove-Item -LiteralPath $oldFile -Force
    }
}

New-Item -ItemType Directory -Force -Path $staging | Out-Null
Copy-Item -LiteralPath $application -Destination (Join-Path $staging "ARTOFFICE-video-maker.exe")
Copy-Item -LiteralPath (Join-Path $vendorTools "ffmpeg") -Destination (Join-Path $staging "tools\ffmpeg") -Recurse
Copy-Item -LiteralPath (Join-Path $vendorTools "imagemagick") -Destination (Join-Path $staging "tools\imagemagick") -Recurse
Copy-Item -LiteralPath (Join-Path $vendorTools "resources") -Destination (Join-Path $staging "resources") -Recurse
Copy-Item -LiteralPath (Join-Path $vendorTools "licenses") -Destination (Join-Path $staging "licenses") -Recurse
Copy-Item -LiteralPath (Join-Path $vendorTools "tools.lock.json") -Destination (Join-Path $staging "tools.lock.json")
Copy-Item -LiteralPath (Join-Path $repoRoot "README.md") -Destination (Join-Path $staging "README.md")
Copy-Item -LiteralPath (Join-Path $repoRoot "THIRD_PARTY_NOTICES.md") -Destination (Join-Path $staging "THIRD_PARTY_NOTICES.md")
Copy-Item -LiteralPath (Join-Path $repoRoot "docs\USER_GUIDE_JA.md") -Destination (Join-Path $staging "USER_GUIDE_JA.md")

Compress-Archive -LiteralPath $staging -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
Set-Content -LiteralPath $checksumPath -Value "$hash  $([IO.Path]::GetFileName($zipPath))" -Encoding ascii

Write-Host "Portable ZIP created: $zipPath"
Write-Host "SHA-256: $hash"
