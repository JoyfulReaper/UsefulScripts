#requires -Version 7.0
#requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$VmName = 'Jumpbox'

$FrontDeskHost = '10.99.0.14'
$FrontDeskUser = 'backup-ryzenshine'
$FrontDeskKey = Join-Path $env:USERPROFILE '.ssh\frontdesk-backup-ryzenshine'

$RemoteBase = '/srv/storage/backups/vms/hyper-v/Jumpbox'
$LocalBase = 'S:\VMBackups'
$StagingBase = Join-Path $LocalBase 'Staging'
$LogDir = 'C:\ProgramData\JoyfulReaper\BackupLogs'

$RetentionCopies = 6

$Stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
$DateDir = Get-Date -Format 'yyyy-MM-dd'

$Stage = Join-Path $StagingBase $Stamp
$Archive = Join-Path $LocalBase "$VmName-$Stamp.tar.gz"
$Manifest = "$Archive.sha256"
$RemoteDir = "$RemoteBase/$DateDir"
$RemoteArchive = "$RemoteDir/$([IO.Path]::GetFileName($Archive))"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir 'Jumpbox-backup.log'

$mutex = [Threading.Mutex]::new($false, 'Global\JoyfulReaper-JumpboxBackup')
$haveLock = $false
$success = $false

function Write-Log
{
    param([Parameter(Mandatory)][string] $Message)

    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
}

function Invoke-Native
{
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter()][string[]] $Arguments = @()
    )

    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0)
    {
        throw "$FilePath exited with code $LASTEXITCODE."
    }
}

try
{
    $haveLock = $mutex.WaitOne(0)

    if (-not $haveLock)
    {
        throw 'Another Jumpbox backup is already running.'
    }

    Write-Log "Jumpbox backup starting: $Stamp"

    foreach ($command in @('tar.exe', 'ssh.exe', 'scp.exe'))
    {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue))
        {
            throw "Required command not found: $command"
        }
    }

    if (-not (Test-Path -LiteralPath $FrontDeskKey -PathType Leaf))
    {
        throw "FrontDesk backup key is missing: $FrontDeskKey"
    }

    $vm = Get-VM -Name $VmName -ErrorAction Stop
    Write-Log "VM state before export: $($vm.State)"

    New-Item -ItemType Directory -Force -Path $Stage | Out-Null

    Write-Log "Exporting live Hyper-V VM to $Stage"
    Export-VM -Name $VmName -Path $Stage -ErrorAction Stop

    $exportRoot = Join-Path $Stage $VmName

    if (-not (Test-Path -LiteralPath $exportRoot -PathType Container))
    {
        throw "Hyper-V export directory was not created: $exportRoot"
    }

    Write-Log "Creating compressed archive: $Archive"
    Invoke-Native -FilePath 'tar.exe' -Arguments @(
        '-C', $Stage,
        '-czf', $Archive,
        $VmName
    )

    if (-not (Test-Path -LiteralPath $Archive -PathType Leaf))
    {
        throw "Archive was not created: $Archive"
    }

    Write-Log 'Testing local archive.'
    Invoke-Native -FilePath 'tar.exe' -Arguments @(
        '-tzf', $Archive
    )

    $archiveInfo = Get-Item -LiteralPath $Archive
    Write-Log ('Archive size: {0:N2} GiB' -f ($archiveInfo.Length / 1GB))

    $hash = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $archiveName = $archiveInfo.Name
    $manifestText = "$hash  $archiveName`n"

    [IO.File]::WriteAllText(
        $Manifest,
        $manifestText,
        [Text.UTF8Encoding]::new($false)
    )

    Write-Log "SHA-256: $hash"

    $sshBase = @(
        '-i', $FrontDeskKey,
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=yes',
        "$FrontDeskUser@$FrontDeskHost"
    )

    Write-Log "Creating FrontDesk destination: $RemoteDir"
    Invoke-Native -FilePath 'ssh.exe' -Arguments (
        $sshBase + @("mkdir -p '$RemoteDir'")
    )

    Write-Log 'Uploading archive and SHA-256 manifest to FrontDesk.'
    Invoke-Native -FilePath 'scp.exe' -Arguments @(
        '-i', $FrontDeskKey,
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=yes',
        $Archive,
        $Manifest,
        "$FrontDeskUser@$FrontDeskHost`:$RemoteDir/"
    )

    Write-Log 'Verifying FrontDesk SHA-256.'
    Invoke-Native -FilePath 'ssh.exe' -Arguments (
        $sshBase + @(
            "cd '$RemoteDir' && sha256sum -c '$([IO.Path]::GetFileName($Manifest))'"
        )
    )

    Write-Log 'Testing FrontDesk compressed archive.'
    Invoke-Native -FilePath 'ssh.exe' -Arguments (
        $sshBase + @(
            "tar -tzf '$RemoteArchive' >/dev/null"
        )
    )

    Write-Log "Applying remote retention: keep newest $RetentionCopies copies."

    # Keep this as a single-line remote command. A PowerShell here-string uses
    # Windows CRLF line endings, which bash on FrontDesk can interpret as
    # literal carriage returns when passed as one ssh argument.
    $retentionStart = $RetentionCopies + 1
    $retentionCommand =
        "cd '$RemoteBase' && find . -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\\n' | sort -nr | tail -n +$retentionStart | cut -d' ' -f2- | xargs -r rm -rf --"

    Invoke-Native -FilePath 'ssh.exe' -Arguments (
        $sshBase + @($retentionCommand)
    )

    $success = $true
    Write-Log "Jumpbox backup completed successfully: $RemoteArchive"
}
catch
{
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log 'Local staging/archive retained for investigation when present.'
    throw
}
finally
{
    if ($success)
    {
        Write-Log 'Cleaning local staging and archive.'

        Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Archive -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Manifest -Force -ErrorAction SilentlyContinue
    }

    if ($haveLock)
    {
        [void] $mutex.ReleaseMutex()
    }

    $mutex.Dispose()
}
