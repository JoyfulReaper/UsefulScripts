param(
    [string]$Root = "C:\GitHub",
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Root)) {
    throw "Root path does not exist: $Root"
}

$targets = Get-ChildItem `
    -LiteralPath $Root `
    -Directory `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @("bin", "obj") }

if (-not $targets) {
    Write-Host "No bin or obj directories found under $Root"
    exit 0
}

$totalBytes = 0

foreach ($directory in $targets) {
    $size = (
        Get-ChildItem `
            -LiteralPath $directory.FullName `
            -File `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    ).Sum

    if ($null -ne $size) {
        $totalBytes += $size
    }

    if ($WhatIf) {
        Write-Host "[Would remove] $($directory.FullName)"
    }
    else {
        Write-Host "[Removing] $($directory.FullName)"
        Remove-Item `
            -LiteralPath $directory.FullName `
            -Recurse `
            -Force `
            -ErrorAction Continue
    }
}

$totalGB = [math]::Round($totalBytes / 1GB, 2)

if ($WhatIf) {
    Write-Host "`nEstimated reclaimable space: $totalGB GB"
}
else {
    Write-Host "`nCleanup complete. Approximate space reclaimed: $totalGB GB"
}