#requires -Version 7.0
#requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$GenericScript = Join-Path $PSScriptRoot 'Backup-HyperVVmToRestic.ps1'

if (-not (Test-Path -LiteralPath $GenericScript -PathType Leaf))
{
    throw "Generic Hyper-V restic backup script is missing: $GenericScript"
}

& $GenericScript `
    -VmName 'Jumpbox' `
    -Repository 'rest:http://10.99.0.14:8000/ryzenshine/' `
    -StagingRoot 'S:\HyperV-Backup-Staging' `
    -LimitUploadKiB 10240 `
    -KeepLast 6
