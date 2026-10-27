param(
    [Parameter(Mandatory)][ValidateSet('start','status','failed-log','download')][string]$Action,
    [ValidateRange(1,2147483647)][int]$BuildId = 1,
    [ValidateSet('all','media','storage','ui','device')][string]$Task = 'device',
    [string]$Revision
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$patFile = Join-Path $repositoryRoot '.secrets/azure-devops-pat.clixml'
$evidenceRoot = Join-Path $repositoryRoot '.cache/ios-evidence'
$apiRoot = 'https://dev.azure.com/yuto200596/ios-development/_apis'
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
if (!(Test-Path -LiteralPath $patFile)) { throw 'Azure PAT has not been saved with Windows DPAPI.' }
$protectedPat = Import-Clixml -LiteralPath $patFile
if ($protectedPat -isnot [Security.SecureString]) { throw 'Expected a DPAPI-protected SecureString.' }
$patPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($protectedPat)
try {
    $patValue = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($patPointer)
    $authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(':' + $patValue))
    $patValue = $null
    $requestHeaders = @{ Authorization = $authorization }
    function Invoke-BuildApi([string]$Path, [string]$Method = 'Get', $Body = $null) {
        $arguments = @{ Uri = "$apiRoot/$Path"; Method = $Method; Headers = $requestHeaders; TimeoutSec = 90 }
        if ($null -ne $Body) { $arguments.Body = ConvertTo-Json $Body -Depth 12 -Compress; $arguments.ContentType = 'application/json' }
        Invoke-RestMethod @arguments
    }
    function Get-BuildSummary($Build) {
        [pscustomobject]@{id=$Build.id;status=$Build.status;result=$Build.result;revision=$Build.sourceVersion;url=$Build._links.web.href}
    }
    switch ($Action) {
        'start' {
            if ($Revision -notmatch '^[0-9a-fA-F]{40}$') { throw 'An explicit full commit SHA is required.' }
            $body = @{
                resources = @{ repositories = @{ self = @{ refName = 'refs/heads/codex/ios-native'; version = $Revision } } }
                templateParameters = @{ task = $Task }
            }
            $run = Invoke-BuildApi 'pipelines/1/runs?api-version=7.1' 'Post' $body
            $build = Invoke-BuildApi "build/builds/$($run.id)?api-version=7.1"
            if ($build.sourceVersion -ne $Revision) { throw "Queued build $($run.id) does not match the requested revision; inspect before using its output." }
            Get-BuildSummary $build | ConvertTo-Json -Compress
        }
        'status' {
            Get-BuildSummary (Invoke-BuildApi "build/builds/${BuildId}?api-version=7.1") | ConvertTo-Json -Compress
        }
        'failed-log' {
            $timeline = Invoke-BuildApi "build/builds/$BuildId/timeline?api-version=7.1"
            $failed = @($timeline.records | Where-Object { $_.type -eq 'Task' -and $_.result -eq 'failed' -and $_.log })
            if (!$failed.Count) { throw 'No failed task with a completed log was found.' }
            foreach ($step in $failed) {
                $log = Invoke-WebRequest -Uri "$apiRoot/build/builds/$BuildId/logs/$($step.log.id)?api-version=7.1" -Headers $requestHeaders -TimeoutSec 90
                $path = Join-Path $evidenceRoot "azure-run-$BuildId-log-$($step.log.id).txt"
                $log.Content | Set-Content -LiteralPath $path -Encoding utf8
                Write-Output "Failed step: $($step.name) / saved log: $path"
                $lines = @($log.Content -split '\r?\n' | Select-String -Pattern 'error:|failed|AssertionError|Traceback|BUILD FAILED|TEST FAILED' -Context 2,3)
                $lines | Select-Object -Last 24 | ForEach-Object { $_.ToString() }
            }
        }
        'download' {
            $build = Invoke-BuildApi "build/builds/${BuildId}?api-version=7.1"
            if ($build.status -ne 'completed' -or $build.result -ne 'succeeded') { throw 'Only a successful completed build can be downloaded for installation.' }
            if ($Revision -and $build.sourceVersion -ne $Revision) { throw 'Build revision mismatch.' }
            $artifacts = Invoke-BuildApi "build/builds/$BuildId/artifacts?api-version=7.1"
            $artifact = @($artifacts.value | Where-Object { $_.name -eq 'ios-signed' })
            if ($artifact.Count -ne 1) { throw 'Expected exactly one ios-signed artifact.' }
            $downloadUri = [Uri]$artifact[0].resource.downloadUrl
            $artifactHosts = @('dev.azure.com', 'artprodsea1.artifacts.visualstudio.com')
            if ($downloadUri.Scheme -ne 'https' -or $downloadUri.Host -notin $artifactHosts) { throw 'Expected the authenticated Azure DevOps artifact endpoint.' }
            $destination = Join-Path $repositoryRoot ".cache/ios-signed/azure-build-$BuildId"
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            $zip = Join-Path $destination 'ios-signed.zip'
            # PowerShell strips Authorization on redirects to artifact storage.
            Invoke-WebRequest -Uri $downloadUri -Headers $requestHeaders -OutFile $zip -TimeoutSec 180
            Expand-Archive -LiteralPath $zip -DestinationPath $destination -Force
            Get-BuildSummary $build | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'build.json') -Encoding utf8
            Write-Output "Signed artifact saved to $destination"
        }
    }
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($patPointer)
    $authorization = $null; $requestHeaders = $null; $protectedPat = $null
}
