#requires -Version 7.0
#requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName = 'Jumpbox Weekly Backup'
$InstallDir = 'C:\ProgramData\JoyfulReaper\Backups'
$InstalledWrapper = Join-Path $InstallDir 'backup-jumpbox.ps1'
$InstalledGeneric = Join-Path $InstallDir 'Backup-HyperVVmToRestic.ps1'

$SourceWrapper = Join-Path $PSScriptRoot 'backup.ps1'
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')
$SourceGeneric = Join-Path $RepoRoot 'windows\hyperv\Backup-HyperVVmToRestic.ps1'

foreach ($source in @($SourceWrapper, $SourceGeneric))
{
    if (-not (Test-Path -LiteralPath $source -PathType Leaf))
    {
        throw "Required source script not found: $source"
    }
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

Copy-Item -LiteralPath $SourceWrapper -Destination $InstalledWrapper -Force
Copy-Item -LiteralPath $SourceGeneric -Destination $InstalledGeneric -Force

$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source

$action = New-ScheduledTaskAction `
    -Execute $pwsh `
    -Argument "-NoLogo -NoProfile -NonInteractive -File `"$InstalledWrapper`""

$trigger = New-ScheduledTaskTrigger `
    -Weekly `
    -WeeksInterval 1 `
    -DaysOfWeek Sunday `
    -At 4:30am `
    -RandomDelay (New-TimeSpan -Minutes 30)

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 3)

Write-Host "The task must use a password-backed logon so the current-user DPAPI secrets"
Write-Host "can be decrypted when the task runs unattended."
Write-Host

$securePassword = Read-Host "Windows password for $userId" -AsSecureString
$passwordPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)

try
{
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPtr)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -User $userId `
        -Password $plainPassword `
        -RunLevel Highest `
        -Description 'Weekly live Hyper-V restic backup of Jumpbox to FrontDesk over WireGuard; keeps the latest 6 snapshots.' `
        -Force |
        Out-Null
}
finally
{
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPtr)
    $plainPassword = $null
}

Write-Host "Installed wrapper: $InstalledWrapper"
Write-Host "Installed generic backup engine: $InstalledGeneric"
Write-Host "Scheduled task: $TaskName"
Write-Host 'Runs weekly Sunday at 04:30 with up to 30 minutes randomized delay.'
Write-Host
Write-Host 'Before relying on the task unattended, start it manually once and confirm:'
Write-Host '  - LastTaskResult is 0'
Write-Host '  - a new Jumpbox restic snapshot exists'
Write-Host '  - the ntfy success notification arrives'
Write-Host

Get-ScheduledTask -TaskName $TaskName |
    Select-Object TaskName, State
