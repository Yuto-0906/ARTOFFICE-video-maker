[CmdletBinding()]
param(
    [string]$CommonName = "ARTOFFICE macOS Distribution"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$directory = Join-Path $repoRoot ".macos-signing"
$opensslCommand = Get-Command "openssl.exe" -ErrorAction SilentlyContinue
$openssl = if ($null -ne $opensslCommand) { $opensslCommand.Source } else {
    Join-Path $env:ProgramFiles "Git\usr\bin\openssl.exe"
}
if (-not (Test-Path -LiteralPath $openssl -PathType Leaf)) {
    throw "OpenSSL was not found. Install Git for Windows."
}
if ($CommonName -match '[/\r\n]') {
    throw "CommonName cannot contain slashes or newlines."
}
if (Test-Path -LiteralPath $directory) {
    throw "Signing material already exists in .macos-signing. It will not be overwritten."
}
New-Item -ItemType Directory -Path $directory | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = Get-Acl -LiteralPath $directory
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object Security.AccessControl.FileSystemAccessRule(
    $identity, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $directory -AclObject $acl

$random = New-Object byte[] 32
$generator = [Security.Cryptography.RandomNumberGenerator]::Create()
$generator.GetBytes($random)
$generator.Dispose()
$password = [Convert]::ToBase64String($random)
$securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
$protectedPassword = ConvertFrom-SecureString -SecureString $securePassword
Set-Content -LiteralPath (Join-Path $directory "key-password.dpapi") -Value $protectedPassword -NoNewline
$key = Join-Path $directory "private-key.pem"
$csr = Join-Path $directory "DeveloperID.certSigningRequest"
try {
    $env:AOV_PRIVATE_KEY_PASSWORD = $password
    & $openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:2048" -aes-256-cbc -pass "env:AOV_PRIVATE_KEY_PASSWORD" -out $key 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "The encrypted private key could not be generated." }
    & $openssl req -new -sha256 -key $key -passin "env:AOV_PRIVATE_KEY_PASSWORD" -out $csr -subj "/CN=$CommonName"
    if ($LASTEXITCODE -ne 0) { throw "The certificate signing request could not be generated." }
    & $openssl req -verify -noout -in $csr 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "CSR verification failed." }
} finally {
    Remove-Item Env:AOV_PRIVATE_KEY_PASSWORD -ErrorAction SilentlyContinue
    $password = $null
}
Write-Host "CSR ready: $csr"
Write-Host "Upload only DeveloperID.certSigningRequest to Apple's Developer ID Application certificate page."
Write-Host "The encrypted private key and DPAPI-protected password stay on this Windows account."
