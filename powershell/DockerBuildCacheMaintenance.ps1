$ErrorActionPreference = "Stop"

$logDir = Join-Path $env:LOCALAPPDATA "DockerMaintenance"
$logFile = Join-Path $logDir "docker-cleanup.log"

New-Item -ItemType Directory -Force $logDir | Out-Null

function Log($Message) {
    "[$(Get-Date -Format o)] $Message" |
        Add-Content -Path $logFile
}

Log "Starting Docker build-cache maintenance."

docker info *> $null

if ($LASTEXITCODE -ne 0) {
    Log "Docker is not running; skipping."
    exit 0
}

docker buildx prune `
    --builder desktop-linux `
    --force `
    --max-used-space 20gb 2>&1 |
    Add-Content -Path $logFile

Log "Finished."

docker system df 2>&1 |
    Add-Content -Path $logFile
