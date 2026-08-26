[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Clip1,
    [Parameter(Mandatory)][string]$Clip2,
    [Parameter(Mandatory)][string]$EventName,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
foreach ($source in @($Clip1,$Clip2)) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Input MP4 does not exist: $source"
    }
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$env:AOV_ACCEPTANCE_CLIP_1 = [IO.Path]::GetFullPath($Clip1)
$env:AOV_ACCEPTANCE_CLIP_2 = [IO.Path]::GetFullPath($Clip2)
$env:AOV_ACCEPTANCE_EVENT = $EventName
$env:AOV_ACCEPTANCE_OUTPUT_DIR = $resolvedOutput

Push-Location $repoRoot
try {
    & cargo test --manifest-path "src-tauri\Cargo.toml" "render::tests::real_media_acceptance_test" -- --ignored --nocapture
    if ($LASTEXITCODE -ne 0) {
        throw "Real-media acceptance test failed."
    }
} finally {
    Pop-Location
    Remove-Item Env:AOV_ACCEPTANCE_CLIP_1 -ErrorAction SilentlyContinue
    Remove-Item Env:AOV_ACCEPTANCE_CLIP_2 -ErrorAction SilentlyContinue
    Remove-Item Env:AOV_ACCEPTANCE_EVENT -ErrorAction SilentlyContinue
    Remove-Item Env:AOV_ACCEPTANCE_OUTPUT_DIR -ErrorAction SilentlyContinue
}
