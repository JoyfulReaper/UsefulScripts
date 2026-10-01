param(
    [string]$SecretRoot = (Join-Path $env:ProgramData "UsefulScripts\HyperVBackup"),

    [string]$RestUsername = "ryzenshine",

    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Test-SecureStringEqual {
    param(
        [Parameter(Mandatory = $true)]
        [Security.SecureString]$First,

        [Parameter(Mandatory = $true)]
        [Security.SecureString]$Second
    )

    $firstPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($First)
    $secondPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Second)

    try {
        $firstPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstPtr)
        $secondPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secondPtr)

        $firstPlain -ceq $secondPlain
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstPtr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondPtr)
        $firstPlain = $null
        $secondPlain = $null
    }
}

function Write-DpapiSecret {
    param(
        [Parameter(Mandatory = $true)]
        [Security.SecureString]$Secret,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $protectedValue = ConvertFrom-SecureString -SecureString $Secret

    Set-Content `
        -LiteralPath $Path `
        -Value $protectedValue `
        -Encoding utf8NoBOM `
        -NoNewline
}

if ($env:OS -ne "Windows_NT") {
    throw "This helper must run on Windows because it uses Windows DPAPI."
}

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name

$secretFiles = @(
    (Join-Path $SecretRoot "restic-rest-username.txt")
    (Join-Path $SecretRoot "restic-rest-password.dpapi")
    (Join-Path $SecretRoot "restic-repository-password.dpapi")
    (Join-Path $SecretRoot "ntfy-token.dpapi")
)

$existingFiles = @($secretFiles | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })

if ($existingFiles.Count -gt 0 -and -not $Force) {
    $existingList = $existingFiles -join [Environment]::NewLine

    throw @"
Backup secret files already exist:

$existingList

Refusing to overwrite them. Re-run with -Force only if you intentionally want to replace all stored backup credentials.
"@
}

Write-Host "Creating Hyper-V backup secret storage."
Write-Host "Windows identity: $currentIdentity"
Write-Host "Secret root:      $SecretRoot"
Write-Host ""

New-Item -ItemType Directory -Path $SecretRoot -Force | Out-Null

& icacls.exe $SecretRoot /grant:r "${currentIdentity}:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Failed to grant ACLs on $SecretRoot"
}

& icacls.exe $SecretRoot /inheritance:r | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Failed to disable inherited ACLs on $SecretRoot"
}

$restServerPassword = Read-Host "rest-server password for $RestUsername" -AsSecureString

$repositoryPassword = Read-Host "restic repository encryption password" -AsSecureString
$repositoryPasswordConfirm = Read-Host "confirm restic repository encryption password" -AsSecureString

if (-not (Test-SecureStringEqual -First $repositoryPassword -Second $repositoryPasswordConfirm)) {
    throw "Repository passwords did not match. Nothing was written."
}

$ntfyToken = Read-Host "ntfy token for RyzenShine backup notifications" -AsSecureString

Set-Content `
    -LiteralPath (Join-Path $SecretRoot "restic-rest-username.txt") `
    -Value $RestUsername `
    -Encoding utf8NoBOM `
    -NoNewline

Write-DpapiSecret `
    -Secret $restServerPassword `
    -Path (Join-Path $SecretRoot "restic-rest-password.dpapi")

Write-DpapiSecret `
    -Secret $repositoryPassword `
    -Path (Join-Path $SecretRoot "restic-repository-password.dpapi")

Write-DpapiSecret `
    -Secret $ntfyToken `
    -Path (Join-Path $SecretRoot "ntfy-token.dpapi")

foreach ($path in $secretFiles | Where-Object { $_ -like "*.dpapi" }) {
    $protectedValue = (Get-Content -LiteralPath $path -Raw).Trim()
    $null = ConvertTo-SecureString -String $protectedValue
}

Write-Host ""
Write-Host "Stored backup credentials successfully."
Write-Host "Task Scheduler must run the backup under this same Windows identity:"
Write-Host "  $currentIdentity"
Write-Host ""
Write-Host "Secret files:"
$secretFiles | ForEach-Object { Write-Host "  $_" }
