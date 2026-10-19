[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CertificatePath,
    [Parameter(Mandatory)][string]$AppleId,
    [Parameter(Mandatory)][ValidatePattern("^[A-Z0-9]{10}$")][string]$TeamId,
    [SecureString]$AppSpecificPassword
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$directory = Join-Path $repoRoot ".macos-signing"
$certificate = (Resolve-Path -LiteralPath $CertificatePath).Path
$opensslCommand = Get-Command "openssl.exe" -ErrorAction SilentlyContinue
$openssl = if ($null -ne $opensslCommand) { $opensslCommand.Source } else {
    Join-Path $env:ProgramFiles "Git\usr\bin\openssl.exe"
}
$gh = (Get-Command "gh.exe" -ErrorAction Stop).Source
$key = Join-Path $directory "private-key.pem"
$passwordFile = Join-Path $directory "key-password.dpapi"
if (-not (Test-Path -LiteralPath $key) -or -not (Test-Path -LiteralPath $passwordFile)) {
    throw "Run scripts/prepare-macos-signing.ps1 on this Windows account first."
}
$x509 = New-Object Security.Cryptography.X509Certificates.X509Certificate2($certificate)
$commonName = $x509.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
if (-not $commonName.StartsWith("Developer ID Application:")) {
    throw "Select a Developer ID Application certificate, not an iOS certificate."
}
if ($x509.Subject -notmatch "(?:^|,\s*)OU=$TeamId(?:,|$)") {
    throw "The certificate's Team ID does not match TeamId."
}
if ($x509.NotAfter -le (Get-Date) -or $x509.NotBefore -gt (Get-Date)) {
    throw "The certificate is not currently valid."
}
function Get-PlainText {
    param([Parameter(Mandatory)][SecureString]$SecureValue)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}
function Set-RepositorySecret {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $gh
    $start.Arguments = "secret set $Name --repo Yuto-0906/ARTOFFICE-video-maker"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    [void]$process.Start()
    $process.StandardInput.Write($Value)
    $process.StandardInput.Close()
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [void]$outputTask.GetAwaiter().GetResult()
    [void]$errorTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw "GitHub Secret registration failed: $Name" }
    $process.Dispose()
    Write-Host "Registered secret: $Name"
}

if ($null -eq $AppSpecificPassword) {
    $AppSpecificPassword = Read-Host "Apple account app-specific password (not your login password)" -AsSecureString
}
$secureKeyPassword = ConvertTo-SecureString -String (Get-Content -Raw -LiteralPath $passwordFile)
$random = New-Object byte[] 32
$generator = [Security.Cryptography.RandomNumberGenerator]::Create()
$generator.GetBytes($random)
$generator.Dispose()
$p12Password = [Convert]::ToBase64String($random)
$pem = Join-Path $directory "developer-id.pem"
$p12 = Join-Path $directory "developer-id.p12"
try {
    $env:AOV_PRIVATE_KEY_PASSWORD = Get-PlainText -SecureValue $secureKeyPassword
    $env:AOV_P12_PASSWORD = $p12Password
    & $openssl x509 -inform DER -in $certificate -out $pem
    if ($LASTEXITCODE -ne 0) { throw "The Apple certificate could not be read as DER." }
    $keyPublic = & $openssl pkey -in $key -passin "env:AOV_PRIVATE_KEY_PASSWORD" -pubout
    if ($LASTEXITCODE -ne 0) { throw "The private key could not be decrypted on this Windows account." }
    $certPublic = & $openssl x509 -in $pem -pubkey -noout
    if ($LASTEXITCODE -ne 0 -or ($keyPublic -join "") -ne ($certPublic -join "")) {
        throw "The certificate does not match this private key. Select the certificate made with this CSR."
    }
    $chain = Join-Path $directory "developer-id-chain.pem"
    $chainText = ""
    foreach ($authority in @("DeveloperIDCA", "DeveloperIDG2CA")) {
        $authorityDer = Join-Path $directory "$authority.cer"
        Invoke-WebRequest -UseBasicParsing -Uri "https://www.apple.com/certificateauthority/$authority.cer" -OutFile $authorityDer
        $authorityPem = & $openssl x509 -inform DER -in $authorityDer
        if ($LASTEXITCODE -ne 0) { throw "Apple's certificate authority file could not be read." }
        $chainText += ($authorityPem -join [Environment]::NewLine) + [Environment]::NewLine
    }
    Set-Content -LiteralPath $chain -Value $chainText -Encoding ascii
    & $openssl pkcs12 -export -legacy -inkey $key -passin "env:AOV_PRIVATE_KEY_PASSWORD" -in $pem -certfile $chain -out $p12 -passout "env:AOV_P12_PASSWORD"
    if ($LASTEXITCODE -ne 0) { throw "The signing PKCS#12 could not be exported." }
    ConvertFrom-SecureString -SecureString (ConvertTo-SecureString -String $p12Password -AsPlainText -Force) |
        Set-Content -LiteralPath (Join-Path $directory "p12-password.dpapi") -NoNewline
    Set-RepositorySecret -Name "APPLE_CERTIFICATE" -Value ([Convert]::ToBase64String([IO.File]::ReadAllBytes($p12)))
    Set-RepositorySecret -Name "APPLE_CERTIFICATE_PASSWORD" -Value $p12Password
    Set-RepositorySecret -Name "APPLE_SIGNING_IDENTITY" -Value $commonName
    Set-RepositorySecret -Name "APPLE_ID" -Value $AppleId
    Set-RepositorySecret -Name "APPLE_TEAM_ID" -Value $TeamId
    Set-RepositorySecret -Name "APPLE_PASSWORD" -Value (Get-PlainText -SecureValue $AppSpecificPassword)
} finally {
    Remove-Item Env:AOV_PRIVATE_KEY_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:AOV_P12_PASSWORD -ErrorAction SilentlyContinue
    $p12Password = $null
    $keyPublic = $null
    $certPublic = $null
}
Write-Host "Mac signing configuration is ready. The Release workflow can now create a signed draft."
