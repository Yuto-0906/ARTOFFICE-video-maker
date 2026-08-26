[CmdletBinding()]
param(
    [string]$Destination = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$lockPath = Join-Path $repoRoot "tools.lock.json"
$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
$cacheRoot = Join-Path $repoRoot ".tool-cache"
New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $destinationPath = Join-Path $repoRoot "vendor-tools"
} elseif ([IO.Path]::IsPathRooted($Destination)) {
    $destinationPath = [IO.Path]::GetFullPath($Destination)
} else {
    $destinationPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $Destination))
}

$repoPrefix = $repoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $destinationPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Runtime tools must be written inside the repository: $destinationPath"
}

function Get-VerifiedFile {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][string]$Label
    )

    $target = Join-Path $cacheRoot ([string]$Artifact.fileName)
    $expected = ([string]$Artifact.sha256).ToUpperInvariant()
    if (Test-Path -LiteralPath $target) {
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToUpperInvariant()
        if ($actual -eq $expected) {
            Write-Host "Using verified cache for $Label."
            return $target
        }
        Remove-Item -LiteralPath $target -Force
    }

    $partial = "$target.partial"
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force
    }
    Write-Host "Downloading $Label."
    try {
        Invoke-WebRequest -Uri ([string]$Artifact.url) -OutFile $partial
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $partial).Hash.ToUpperInvariant()
        if ($actual -ne $expected) {
            throw "$Label SHA-256 mismatch. Expected=$expected Actual=$actual"
        }
        Move-Item -LiteralPath $partial -Destination $target -Force
    } finally {
        if (Test-Path -LiteralPath $partial) {
            Remove-Item -LiteralPath $partial -Force
        }
    }
    return $target
}

function Get-SevenZip {
    $command = Get-Command "7z.exe" -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    $standardPath = "C:\Program Files\7-Zip\7z.exe"
    if (Test-Path -LiteralPath $standardPath) {
        return $standardPath
    }
    throw "7-Zip is required to unpack ImageMagick. Install it from https://www.7-zip.org/."
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("artoffice-tools-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null

try {
    $ffmpegArchive = Get-VerifiedFile -Artifact $lock.ffmpeg -Label "FFmpeg $($lock.ffmpeg.version)"
    $imageMagickArchive = Get-VerifiedFile -Artifact $lock.imageMagick -Label "ImageMagick $($lock.imageMagick.version)"
    $fontSource = Get-VerifiedFile -Artifact $lock.notoSansJp -Label "Noto Sans JP $($lock.notoSansJp.version)"

    $licenseArtifact = [PSCustomObject]@{
        fileName = [string]$lock.notoSansJp.licenseFileName
        url = [string]$lock.notoSansJp.licenseUrl
        sha256 = [string]$lock.notoSansJp.licenseSha256
    }
    $fontLicense = Get-VerifiedFile -Artifact $licenseArtifact -Label "Noto Sans JP license"

    $ffmpegExpanded = Join-Path $temporaryRoot "ffmpeg"
    Expand-Archive -LiteralPath $ffmpegArchive -DestinationPath $ffmpegExpanded
    $ffmpegRoot = Get-ChildItem -LiteralPath $ffmpegExpanded -Directory | Select-Object -First 1
    if ($null -eq $ffmpegRoot) {
        throw "The FFmpeg archive layout is not recognized."
    }

    $imageMagickExpanded = Join-Path $temporaryRoot "imagemagick"
    New-Item -ItemType Directory -Force -Path $imageMagickExpanded | Out-Null
    $sevenZip = Get-SevenZip
    & $sevenZip x $imageMagickArchive "-o$imageMagickExpanded" -y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "The ImageMagick archive could not be unpacked."
    }

    $python = Get-Command "python.exe" -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        throw "Python is required to generate Noto Sans JP Black."
    }
    $fontToolsVersion = & $python.Source -c "import fontTools; print(fontTools.__version__)"
    if ($LASTEXITCODE -ne 0 -or $fontToolsVersion.Trim() -ne [string]$lock.buildDependencies.fontToolsVersion) {
        throw "fonttools $($lock.buildDependencies.fontToolsVersion) is required. Run: python -m pip install fonttools==$($lock.buildDependencies.fontToolsVersion)"
    }
    $generatedFont = Join-Path $temporaryRoot "NotoSansJP-Black.ttf"
    & $python.Source -m fontTools.varLib.instancer $fontSource "wght=900" --update-name-table --no-recalc-timestamp --output $generatedFont
    if ($LASTEXITCODE -ne 0) {
        throw "Noto Sans JP Black could not be generated."
    }
    $fontHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $generatedFont).Hash.ToUpperInvariant()
    if ($fontHash -ne ([string]$lock.notoSansJp.generatedBlackSha256).ToUpperInvariant()) {
        throw "Generated Noto Sans JP Black SHA-256 mismatch: $fontHash"
    }

    if (Test-Path -LiteralPath $destinationPath) {
        $resolvedDestination = (Resolve-Path -LiteralPath $destinationPath).Path
        if (-not $resolvedDestination.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a directory outside the repository: $resolvedDestination"
        }
        Remove-Item -LiteralPath $resolvedDestination -Recurse -Force
    }

    $ffmpegDestination = Join-Path $destinationPath "ffmpeg\bin"
    $imageMagickDestination = Join-Path $destinationPath "imagemagick"
    $fontDestination = Join-Path $destinationPath "resources\fonts"
    $licenseDestination = Join-Path $destinationPath "licenses"
    New-Item -ItemType Directory -Force -Path $ffmpegDestination,$imageMagickDestination,$fontDestination,$licenseDestination | Out-Null

    Copy-Item -LiteralPath (Join-Path $ffmpegRoot.FullName "bin\ffmpeg.exe") -Destination $ffmpegDestination
    Copy-Item -LiteralPath (Join-Path $ffmpegRoot.FullName "bin\ffprobe.exe") -Destination $ffmpegDestination
    Copy-Item -LiteralPath (Join-Path $ffmpegRoot.FullName "LICENSE") -Destination (Join-Path $licenseDestination "FFmpeg-GPL-3.0.txt")
    Copy-Item -LiteralPath (Join-Path $ffmpegRoot.FullName "README.txt") -Destination (Join-Path $licenseDestination "FFmpeg-README.txt")

    foreach ($name in @("magick.exe", "LICENSE.txt", "NOTICE.txt", "sRGB.icc")) {
        Copy-Item -LiteralPath (Join-Path $imageMagickExpanded $name) -Destination $imageMagickDestination
    }
    Get-ChildItem -LiteralPath $imageMagickExpanded -Filter "*.xml" -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $imageMagickDestination
    }
    Copy-Item -LiteralPath (Join-Path $imageMagickExpanded "LICENSE.txt") -Destination (Join-Path $licenseDestination "ImageMagick-LICENSE.txt")
    Copy-Item -LiteralPath (Join-Path $imageMagickExpanded "NOTICE.txt") -Destination (Join-Path $licenseDestination "ImageMagick-NOTICE.txt")

    Copy-Item -LiteralPath $generatedFont -Destination (Join-Path $fontDestination "NotoSansJP-Black.ttf")
    Copy-Item -LiteralPath $fontLicense -Destination (Join-Path $licenseDestination "NotoSansJP-OFL.txt")
    Copy-Item -LiteralPath $lockPath -Destination (Join-Path $destinationPath "tools.lock.json")

    $ffmpegLine = & (Join-Path $ffmpegDestination "ffmpeg.exe") -version | Select-Object -First 1
    if ($ffmpegLine -notmatch [Regex]::Escape([string]$lock.ffmpeg.version)) {
        throw "Prepared FFmpeg has an unexpected version: $ffmpegLine"
    }
    $formats = & (Join-Path $imageMagickDestination "magick.exe") -list format
    if (-not ($formats | Select-String -Quiet "^\s*HEIC\s+r--")) {
        throw "Prepared ImageMagick does not include the HEIC decoder."
    }

    Write-Host "Runtime tools are ready: $destinationPath"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = (Resolve-Path -LiteralPath $temporaryRoot).Path
        $systemTemporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolvedTemporary.StartsWith($systemTemporary, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
        }
    }
}
