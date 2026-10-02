#requires -Version 7.0
#requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName = 'ArchLinux Biweekly Backup'
$InstallDir = 'C:\ProgramData\JoyfulReaper\Backups'
$InstalledWrapper = Join-Path $InstallDir 'backup-archlinux.ps1'
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

if (-not (Get-VM -Name 'ArchLinux' -ErrorAction SilentlyContinue))
{
    throw "ArchLinux is not currently registered in Hyper-V."
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

Copy-Item -LiteralPath $SourceWrapper -Destination $InstalledWrapper -Force
Copy-Item -LiteralPath $SourceGeneric -Destination $InstalledGeneric -Force

$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source

$action = New-ScheduledTaskAction `
    -Execute $pwsh `
    -Argument "-NoLogo -NoProfile -NonInteractive -File `"$InstalledWrapper`""

# Run every two weeks, after the other RyzenShine VM backup windows.
$trigger = New-ScheduledTaskTrigger `
    -Weekly `
    -WeeksInterval 2 `
    -DaysOfWeek Sunday `
    -At 7:30am `
    -RandomDelay (New-TimeSpan -Minutes 30)

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 6)

Write-Host "The task uses a password-backed logon so the current-user DPAPI secrets"
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
        -Description 'Live Hyper-V restic backup of ArchLinux to FrontDesk every two weeks; keeps the latest 6 snapshots.' `
        -Force `
        -ErrorAction Stop |
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
Write-Host 'Runs every two weeks on Sunday at 07:30 with up to 30 minutes randomized delay.'
Write-Host
Write-Host 'Before relying on the task unattended, start it manually once and confirm:'
Write-Host '  - LastTaskResult is 0'
Write-Host '  - a new ArchLinux restic snapshot exists'
Write-Host '  - the ntfy success notification arrives'
Write-Host

Get-ScheduledTask -TaskName $TaskName |
    Select-Object TaskName, State
