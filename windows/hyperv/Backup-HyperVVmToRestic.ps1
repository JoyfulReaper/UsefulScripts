param(
    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $true)]
    [string]$Repository,

    [Parameter(Mandatory = $true)]
    [string]$StagingRoot,

    [int]$LimitUploadKiB = 20480,

    [int]$KeepLast = 3,

    [switch]$SkipPrune
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ==="
}

function Require-EnvVar {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name))) {
        throw "Missing required environment variable: $Name"
    }
}

Require-EnvVar "RESTIC_REST_USERNAME"
Require-EnvVar "RESTIC_REST_PASSWORD"
Require-EnvVar "RESTIC_PASSWORD"

$exportDir = Join-Path $StagingRoot $VmName

$startedAt = Get-Date
$snapshotCreated = $false

Write-Step "Backup starting"
Write-Host "VM:          $VmName"
Write-Host "Repository:  $Repository"
Write-Host "Staging:     $exportDir"
Write-Host "Throttle:    $LimitUploadKiB KiB/s"
Write-Host "Started:     $startedAt"

try {
    Write-Step "Checking VM"
    $vm = Get-VM -Name $VmName
    $vm | Select-Object Name, State, Status, Generation | Format-List

    $checkpoints = Get-VMSnapshot -VMName $VmName -ErrorAction SilentlyContinue
    if ($checkpoints) {
        throw "VM has checkpoints. Refusing backup until checkpoints are reviewed/merged."
    }

	Write-Step "Checking staging directory"

	if (Test-Path $exportDir) {
		throw "Staging directory already exists: $exportDir. A previous backup may have failed; inspect it before continuing."
	}

	Write-Step "Creating staging directory"
	New-Item -ItemType Directory -Path $exportDir | Out-Null

    Write-Step "Exporting VM"
    Export-VM -Name $VmName -Path $exportDir

    Write-Step "Measuring export"
    $exportBytes = (Get-ChildItem $exportDir -Recurse -Force -File | Measure-Object Length -Sum).Sum
    $exportGiB = [math]::Round($exportBytes / 1GB, 2)
    Write-Host "Export size: $exportGiB GiB"

    Write-Step "Running restic backup"
	restic -r $Repository backup $exportDir `
		--tag hyperv `
		--tag $VmName `
		--limit-upload $LimitUploadKiB

    if ($LASTEXITCODE -ne 0) {
        throw "restic backup failed with exit code $LASTEXITCODE"
    }

    $snapshotCreated = $true

    Write-Step "Listing snapshots"
    restic -r $Repository snapshots --tag $VmName

    if (-not $SkipPrune) {
        Write-Step "Applying retention"
        restic -r $Repository forget `
            --tag hyperv `
            --tag $VmName `
            --keep-last $KeepLast `
            --prune

        if ($LASTEXITCODE -ne 0) {
            throw "restic forget/prune failed with exit code $LASTEXITCODE"
        }
    }
    else {
        Write-Step "Skipping prune"
    }

    Write-Step "Cleaning staging export"
    Remove-Item $exportDir -Recurse -Force

    $endedAt = Get-Date
    $duration = $endedAt - $startedAt

    Write-Step "Backup completed"
    Write-Host "VM:       $VmName"
    Write-Host "Duration: $duration"
    Write-Host "Ended:    $endedAt"
}
catch {
    Write-Host ""
    Write-Host "BACKUP FAILED: $($_.Exception.Message)" -ForegroundColor Red

    if (Test-Path $exportDir) {
        Write-Host ""
        Write-Host "Staging export was left in place for inspection:"
        Write-Host $exportDir
    }

    throw
}