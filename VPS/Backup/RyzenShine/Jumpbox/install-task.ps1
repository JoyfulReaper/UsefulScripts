#requires -Version 7.0
#requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName = 'Jumpbox Weekly Backup'
$InstallDir = 'C:\ProgramData\JoyfulReaper\Backups'
$InstalledScript = Join-Path $InstallDir 'backup-jumpbox.ps1'

$SourceScript = Join-Path $PSScriptRoot 'backup.ps1'

if (-not (Test-Path -LiteralPath $SourceScript -PathType Leaf))
{
    throw "Cannot find backup.ps1 next to this installer: $SourceScript"
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -LiteralPath $SourceScript -Destination $InstalledScript -Force

$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source

$action = New-ScheduledTaskAction `
    -Execute $pwsh `
    -Argument "-NoLogo -NoProfile -NonInteractive -File `"$InstalledScript`""

$trigger = New-ScheduledTaskTrigger `
    -Weekly `
    -WeeksInterval 1 `
    -DaysOfWeek Sunday `
    -At 4:30am `
    -RandomDelay (New-TimeSpan -Minutes 30)

$principal = New-ScheduledTaskPrincipal `
    -UserId $userId `
    -LogonType S4U `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 3)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Weekly live Hyper-V export of Jumpbox to FrontDesk over WireGuard.' `
    -Force |
    Out-Null

Write-Host "Installed: $InstalledScript"
Write-Host "Scheduled task: $TaskName"
Write-Host 'Runs weekly Sunday at 04:30 with up to 30 minutes randomized delay.'
Write-Host

Get-ScheduledTask -TaskName $TaskName |
    Select-Object TaskName, State
