param(
    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $true)]
    [string]$Repository,

    [Parameter(Mandatory = $true)]
    [string]$StagingRoot,

    [int]$LimitUploadKiB = 20480,

    [int]$KeepLast = 3,

    [string]$NtfyUrl = "http://10.99.0.1:5197/vps-backups",

    [string]$RestUsername,

    [string]$SecretRoot = (Join-Path $env:ProgramData "UsefulScripts\HyperVBackup"),

    [switch]$SkipRetention,

    [switch]$SkipNotifications
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)

    Write-Host ""
    Write-Host "=== $Message ==="
}

function Require-EnvVar {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name, "Process"))) {
        throw "Missing required environment variable: $Name"
    }
}

function Import-DpapiSecret {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Secret file not found: $Path"
    }

    $protectedValue = (Get-Content -LiteralPath $Path -Raw).Trim()

    if ([string]::IsNullOrWhiteSpace($protectedValue)) {
        throw "Secret file is empty: $Path"
    }

    if ($protectedValue.StartsWith("dpapi-machine-v1:")) {
        $cipherBytes = [Convert]::FromBase64String(
            $protectedValue.Substring("dpapi-machine-v1:".Length)
        )

        try {
            $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
                $cipherBytes,
                $null,
                [Security.Cryptography.DataProtectionScope]::LocalMachine
            )

            try {
                return [Text.Encoding]::UTF8.GetString($plainBytes)
            }
            finally {
                [Array]::Clear($plainBytes, 0, $plainBytes.Length)
            }
        }
        finally {
            [Array]::Clear($cipherBytes, 0, $cipherBytes.Length)
        }
    }

    try {
        $secureValue = ConvertTo-SecureString -String $protectedValue
    }
    catch {
        throw "Unable to decrypt legacy CurrentUser DPAPI secret '$Path'."
    }

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)

    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Set-ProcessEnvFromDpapiSecret {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name, "Process"))) {
        return
    }

    $plainText = Import-DpapiSecret -Path $Path

    try {
        [Environment]::SetEnvironmentVariable($Name, $plainText, "Process")
    }
    finally {
        $plainText = $null
    }
}

function Initialize-BackupCredentials {
    if (-not $SkipNotifications -and [string]::IsNullOrWhiteSpace($env:NTFY_TOKEN)) {
        $ntfyTokenPath = Join-Path $SecretRoot "ntfy-token.dpapi"

        if (Test-Path -LiteralPath $ntfyTokenPath -PathType Leaf) {
            try {
                Set-ProcessEnvFromDpapiSecret -Name "NTFY_TOKEN" -Path $ntfyTokenPath
            }
            catch {
                Write-Warning "Unable to load ntfy token from DPAPI storage: $($_.Exception.Message)"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($env:RESTIC_REST_USERNAME)) {
        if (-not [string]::IsNullOrWhiteSpace($RestUsername)) {
            $env:RESTIC_REST_USERNAME = $RestUsername
        }
        else {
            $usernamePath = Join-Path $SecretRoot "restic-rest-username.txt"

            if (Test-Path -LiteralPath $usernamePath -PathType Leaf) {
                $env:RESTIC_REST_USERNAME = (Get-Content -LiteralPath $usernamePath -Raw).Trim()
            }
        }
    }

    Set-ProcessEnvFromDpapiSecret `
        -Name "RESTIC_REST_PASSWORD" `
        -Path (Join-Path $SecretRoot "restic-rest-password.dpapi")

    Set-ProcessEnvFromDpapiSecret `
        -Name "RESTIC_PASSWORD" `
        -Path (Join-Path $SecretRoot "restic-repository-password.dpapi")

    Require-EnvVar "RESTIC_REST_USERNAME"
    Require-EnvVar "RESTIC_REST_PASSWORD"
    Require-EnvVar "RESTIC_PASSWORD"
}

function Format-Duration {
    param([TimeSpan]$Duration)

    "{0}m {1:00}s" -f [math]::Floor($Duration.TotalMinutes), $Duration.Seconds
}

function Send-NtfyNotification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [ValidateSet("min", "low", "default", "high", "max")]
        [string]$Priority,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Tags
    )

    if ($SkipNotifications) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($env:NTFY_TOKEN)) {
        Write-Warning "NTFY_TOKEN is not set; notification skipped."
        return
    }

    $headers = @{
        Authorization = "Bearer $env:NTFY_TOKEN"
        Title         = $Title
        Priority      = $Priority
    }

    if (-not [string]::IsNullOrWhiteSpace($Tags)) {
        $headers.Tags = $Tags
    }

    try {
        Invoke-RestMethod `
            -Uri $NtfyUrl `
            -Method Post `
            -Headers $headers `
            -Body $Message `
            -ContentType "text/plain; charset=utf-8" `
            -TimeoutSec 10 `
            | Out-Null
    }
    catch {
        Write-Warning "ntfy notification failed: $($_.Exception.Message)"
    }
}

$exportDir = Join-Path $StagingRoot $VmName
$startedAt = Get-Date
$currentStage = "startup"
$exportGiB = $null
$snapshotId = $null
$hostName = if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
    [System.Net.Dns]::GetHostName()
}
else {
    $env:COMPUTERNAME
}

Write-Step "Backup starting"
Write-Host "VM:          $VmName"
Write-Host "Repository:  $Repository"
Write-Host "Staging:     $exportDir"
Write-Host "Throttle:    $LimitUploadKiB KiB/s"
Write-Host "Started:     $startedAt"

try {
    $currentStage = "credential loading"

    Initialize-BackupCredentials

    $currentStage = "VM preflight"

    Write-Step "Checking VM"
    $vm = Get-VM -Name $VmName
    $vm | Select-Object Name, State, Status, Generation | Format-List

    $checkpoints = Get-VMSnapshot -VMName $VmName -ErrorAction SilentlyContinue
    if ($checkpoints) {
        throw "VM has checkpoints. Refusing backup until checkpoints are reviewed/merged."
    }

    $currentStage = "staging initialization"

    Write-Step "Checking staging directory"

    if (Test-Path $exportDir) {
        throw "Staging directory already exists: $exportDir. A previous backup may have failed; inspect it before continuing."
    }

    Write-Step "Creating staging directory"
    New-Item -ItemType Directory -Path $exportDir | Out-Null

    $currentStage = "Hyper-V export"

    Write-Step "Exporting VM"
    Export-VM -Name $VmName -Path $exportDir

    Write-Step "Measuring export"
    $exportBytes = (Get-ChildItem $exportDir -Recurse -Force -File | Measure-Object Length -Sum).Sum
    $exportGiB = [math]::Round($exportBytes / 1GB, 2)
    Write-Host "Export size: $exportGiB GiB"

    $currentStage = "restic backup"

    Write-Step "Running restic backup"
    restic -r $Repository backup $exportDir `
        --tag hyperv `
        --tag $VmName `
        --limit-upload $LimitUploadKiB

    if ($LASTEXITCODE -ne 0) {
        throw "restic backup failed with exit code $LASTEXITCODE"
    }

    $currentStage = "snapshot verification"

    Write-Step "Listing snapshots"
    restic -r $Repository snapshots --tag "hyperv,$VmName"

    if ($LASTEXITCODE -ne 0) {
        throw "restic snapshots failed with exit code $LASTEXITCODE"
    }

    try {
        $latestSnapshotJson = restic -r $Repository snapshots `
            --tag "hyperv,$VmName" `
            --latest 1 `
            --json

        if ($LASTEXITCODE -eq 0) {
            $latestSnapshot = $latestSnapshotJson |
                ConvertFrom-Json |
                Select-Object -First 1

            if ($latestSnapshot.id) {
                $snapshotId = $latestSnapshot.id.Substring(0, [math]::Min(8, $latestSnapshot.id.Length))
            }
        }
    }
    catch {
        Write-Warning "Unable to capture latest snapshot ID for notification: $($_.Exception.Message)"
    }

    if (-not $SkipRetention) {
        $currentStage = "retention"

        Write-Step "Applying retention"

        restic -r $Repository forget `
            --tag "hyperv,$VmName" `
            --keep-last $KeepLast

        if ($LASTEXITCODE -ne 0) {
            throw "restic forget failed with exit code $LASTEXITCODE"
        }
    }
    else {
        Write-Step "Skipping retention"
    }

    $currentStage = "staging cleanup"

    Write-Step "Cleaning staging export"
    Remove-Item $exportDir -Recurse -Force

    $endedAt = Get-Date
    $duration = $endedAt - $startedAt
    $durationText = Format-Duration $duration

    $currentStage = "complete"

    Write-Step "Backup completed"
    Write-Host "VM:       $VmName"
    Write-Host "Duration: $duration"
    Write-Host "Ended:    $endedAt"

    $successLines = @(
        "Host: $hostName"
        "VM: $VmName"
        "Runtime: $durationText"
        "Export size: $exportGiB GiB"
        "Throttle: $LimitUploadKiB KiB/s"
        "Retention: $(if ($SkipRetention) { 'skipped' } else { "keep last $KeepLast" })"
    )

    if ($snapshotId) {
        $successLines += "Snapshot: $snapshotId"
    }

    Send-NtfyNotification `
        -Title "$hostName $VmName backup succeeded" `
        -Priority "default" `
        -Tags "white_check_mark,floppy_disk" `
        -Message ($successLines -join [Environment]::NewLine)
}
catch {
    $failure = $_
    $endedAt = Get-Date
    $duration = $endedAt - $startedAt
    $durationText = Format-Duration $duration
    $stagingRetained = Test-Path $exportDir

    Write-Host ""
    Write-Host "BACKUP FAILED: $($failure.Exception.Message)" -ForegroundColor Red

    if ($stagingRetained) {
        Write-Host ""
        Write-Host "Staging export was left in place for inspection:"
        Write-Host $exportDir
    }

    $failureMessage = @(
        "Host: $hostName"
        "VM: $VmName"
        "Stage: $currentStage"
        "Runtime: $durationText"
        "Staging retained: $stagingRetained"
        "Error: $($failure.Exception.Message)"
    ) -join [Environment]::NewLine

    Send-NtfyNotification `
        -Title "$hostName $VmName backup FAILED" `
        -Priority "high" `
        -Tags "x,floppy_disk" `
        -Message $failureMessage

    throw
}
