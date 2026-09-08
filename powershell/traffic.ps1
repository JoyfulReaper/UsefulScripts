$ErrorActionPreference = 'Stop'

# ============================================================================
# IPv4 vs IPv6 Real-Time Traffic Monitor
#
# Measures observed packet sizes using Windows Packet Monitor (pktmon).
# Tracks traffic belonging to this Windows host across its local IP addresses.
#
# Controls:
#   P = Pause/resume display
#   Q = Quit
#   Ctrl+C = Quit
#
# Run from an Administrator PowerShell.
# ============================================================================

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if (-not (Test-IsAdministrator)) {
    Write-Host "This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

if (-not (Get-Command pktmon.exe -ErrorAction SilentlyContinue)) {
    Write-Host "pktmon.exe was not found." -ForegroundColor Red
    exit 1
}

if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
    Write-Host "Start-ThreadJob was not found." -ForegroundColor Red
    Write-Host "Run this script from PowerShell 7." -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
# Find usable local addresses.
#
# Ignore:
#   - loopback
#   - IPv4 APIPA
#   - IPv6 link-local
# ---------------------------------------------------------------------------

$ipv4Addresses = @(
    Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred |
        Where-Object {
            $_.IPAddress -ne '127.0.0.1' -and
            $_.IPAddress -notlike '169.254.*'
        } |
        Select-Object -ExpandProperty IPAddress -Unique
)

$ipv6Addresses = @(
    Get-NetIPAddress -AddressFamily IPv6 -AddressState Preferred |
        Where-Object {
            $_.IPAddress -ne '::1' -and
            $_.IPAddress -notlike 'fe80:*'
        } |
        Select-Object -ExpandProperty IPAddress -Unique
)

$totalAddressCount = $ipv4Addresses.Count + $ipv6Addresses.Count

if ($totalAddressCount -eq 0) {
    Write-Host "No usable IPv4 or IPv6 addresses were found." -ForegroundColor Red
    exit 1
}

# pktmon supports up to 32 filters.
if ($totalAddressCount -gt 32) {
    Write-Host "Too many local addresses for pktmon filters: $totalAddressCount" `
        -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Clean old pktmon state.
# ---------------------------------------------------------------------------

try {
    & pktmon stop 2>$null | Out-Null
} catch {
}

try {
    & pktmon filter remove 2>$null | Out-Null
} catch {
}

# ---------------------------------------------------------------------------
# Add filters.
#
# IPv4 filters are added first, followed by IPv6 filters. This lets the
# capture thread determine the IP version from the filter number.
# ---------------------------------------------------------------------------

$filterId = 0

foreach ($ip in $ipv4Addresses) {
    $filterId++

    & pktmon filter add "IPv4-$filterId" `
        --data-link IPv4 `
        --ip-address $ip |
        Out-Null
}

$lastIPv4FilterId = $filterId

foreach ($ip in $ipv6Addresses) {
    $filterId++

    & pktmon filter add "IPv6-$filterId" `
        --data-link IPv6 `
        --ip-address $ip |
        Out-Null
}

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------

[long]$totalV4In  = 0
[long]$totalV4Out = 0
[long]$totalV6In  = 0
[long]$totalV6Out = 0

[long]$sampleV4In  = 0
[long]$sampleV4Out = 0
[long]$sampleV6In  = 0
[long]$sampleV6Out = 0

$paused = $false
$captureJob = $null

try {
    # -----------------------------------------------------------------------
    # Start real-time pktmon capture.
    #
    # pktmon can report one packet several times as it moves through Windows'
    # networking stack. PktGroupId + PktNumber are used to deduplicate those
    # appearances.
    # -----------------------------------------------------------------------

    $captureJob = Start-ThreadJob -ArgumentList $lastIPv4FilterId -ScriptBlock {
        param(
            [int]$LastIPv4FilterId
        )

        $seenPackets = [System.Collections.Generic.HashSet[string]]::new()
        $seenOrder   = [System.Collections.Generic.Queue[string]]::new()

        & pktmon start `
            --capture `
            --comp nics `
            --pkt-size 64 `
            --log-mode real-time 2>&1 |
            ForEach-Object {

                $line = [string]$_

                $groupMatch = [regex]::Match(
                    $line,
                    'PktGroupId\s+(\d+)'
                )

                if (-not $groupMatch.Success) {
                    return
                }

                $numberMatch = [regex]::Match(
                    $line,
                    'PktNumber\s+(\d+)'
                )

                $directionMatch = [regex]::Match(
                    $line,
                    'Direction\s+(Tx|Rx)'
                )

                $filterMatch = [regex]::Match(
                    $line,
                    'Filter\s+(\d+)'
                )

                $sizeMatch = [regex]::Match(
                    $line,
                    'OriginalSize\s+(\d+)'
                )

                if (
                    -not $numberMatch.Success -or
                    -not $directionMatch.Success -or
                    -not $filterMatch.Success -or
                    -not $sizeMatch.Success
                ) {
                    return
                }

                $groupId = $groupMatch.Groups[1].Value
                $packetNumber = $numberMatch.Groups[1].Value
                $packetKey = "$groupId/$packetNumber"

                # Ignore duplicate appearances of the same packet.
                if (-not $seenPackets.Add($packetKey)) {
                    return
                }

                $seenOrder.Enqueue($packetKey)

                # Prevent the dedupe set from growing forever.
                if ($seenOrder.Count -gt 20000) {
                    for ($i = 0; $i -lt 10000; $i++) {
                        $oldKey = $seenOrder.Dequeue()
                        $seenPackets.Remove($oldKey) | Out-Null
                    }
                }

                $filter = [int]$filterMatch.Groups[1].Value
                $size = [long]$sizeMatch.Groups[1].Value
                $direction = $directionMatch.Groups[1].Value

                if (
                    $LastIPv4FilterId -gt 0 -and
                    $filter -le $LastIPv4FilterId
                ) {
                    $version = 4
                }
                else {
                    $version = 6
                }

                [pscustomobject]@{
                    Version   = $version
                    Direction = $direction
                    Bytes     = $size
                }
            }
    }

    $lastDisplay = Get-Date

    :monitorLoop while ($true) {

        Start-Sleep -Milliseconds 100

        # -------------------------------------------------------------------
        # Always drain packets from the capture job.
        #
        # Totals continue accumulating even while the DISPLAY is paused.
        # Real-time sample counters do not accumulate while paused.
        # -------------------------------------------------------------------

        $packets = @(Receive-Job -Job $captureJob)

        foreach ($packet in $packets) {

            if ($packet.Version -eq 4) {

                if ($packet.Direction -eq 'Rx') {
                    $totalV4In += $packet.Bytes

                    if (-not $paused) {
                        $sampleV4In += $packet.Bytes
                    }
                }
                else {
                    $totalV4Out += $packet.Bytes

                    if (-not $paused) {
                        $sampleV4Out += $packet.Bytes
                    }
                }
            }
            elseif ($packet.Version -eq 6) {

                if ($packet.Direction -eq 'Rx') {
                    $totalV6In += $packet.Bytes

                    if (-not $paused) {
                        $sampleV6In += $packet.Bytes
                    }
                }
                else {
                    $totalV6Out += $packet.Bytes

                    if (-not $paused) {
                        $sampleV6Out += $packet.Bytes
                    }
                }
            }
        }

        if ($captureJob.State -in @('Failed', 'Completed', 'Stopped')) {
            throw "pktmon capture stopped unexpectedly."
        }

        # -------------------------------------------------------------------
        # Keyboard controls
        # -------------------------------------------------------------------

        while ([Console]::KeyAvailable) {

            $key = [Console]::ReadKey($true)

            switch ($key.Key) {

                'P' {
                    $paused = -not $paused

                    # Start a fresh speed sample after pausing/resuming.
                    $sampleV4In  = 0
                    $sampleV4Out = 0
                    $sampleV6In  = 0
                    $sampleV6Out = 0

                    $lastDisplay = Get-Date

                    if ($paused) {
                        Write-Host ""
                        Write-Host "=== PAUSED - select/copy text now. Press P to resume ===" `
                            -ForegroundColor Yellow
                    }
                    else {
                        Clear-Host
                        Write-Host "Resuming..." -ForegroundColor Green
                    }
                }

                'Q' {
                    break monitorLoop
                }
            }
        }

        # While paused, continue counting totals but do not redraw anything.
        if ($paused) {
            $lastDisplay = Get-Date
            continue
        }

        $now = Get-Date
        $elapsed = ($now - $lastDisplay).TotalSeconds

        if ($elapsed -lt 1) {
            continue
        }

        # -------------------------------------------------------------------
        # Real-time speeds
        # -------------------------------------------------------------------

        $v4InSpeed = [math]::Round(
            ($sampleV4In / 1KB) / $elapsed,
            1
        )

        $v4OutSpeed = [math]::Round(
            ($sampleV4Out / 1KB) / $elapsed,
            1
        )

        $v6InSpeed = [math]::Round(
            ($sampleV6In / 1KB) / $elapsed,
            1
        )

        $v6OutSpeed = [math]::Round(
            ($sampleV6Out / 1KB) / $elapsed,
            1
        )

        # -------------------------------------------------------------------
        # Accumulated totals
        # -------------------------------------------------------------------

        $v4InMB  = [math]::Round($totalV4In / 1MB, 2)
        $v4OutMB = [math]::Round($totalV4Out / 1MB, 2)

        $v6InMB  = [math]::Round($totalV6In / 1MB, 2)
        $v6OutMB = [math]::Round($totalV6Out / 1MB, 2)

        # -------------------------------------------------------------------
        # Real-time IPv4/IPv6 split.
        #
        # RX + TX are included.
        # -------------------------------------------------------------------

        $sampleV4Total = $sampleV4In + $sampleV4Out
        $sampleV6Total = $sampleV6In + $sampleV6Out
        $sampleTotal = $sampleV4Total + $sampleV6Total

        if ($sampleTotal -gt 0) {

            $v4RealtimePct = [math]::Round(
                ($sampleV4Total / $sampleTotal) * 100
            )

            $v6RealtimePct = 100 - $v4RealtimePct
        }
        else {
            $v4RealtimePct = 0
            $v6RealtimePct = 0
        }

        # -------------------------------------------------------------------
        # Overall session split.
        # -------------------------------------------------------------------

        $totalV4 = $totalV4In + $totalV4Out
        $totalV6 = $totalV6In + $totalV6Out
        $totalTraffic = $totalV4 + $totalV6

        if ($totalTraffic -gt 0) {

            $v4TotalPct = [math]::Round(
                ($totalV4 / $totalTraffic) * 100
            )

            $v6TotalPct = 100 - $v4TotalPct
        }
        else {
            $v4TotalPct = 0
            $v6TotalPct = 0
        }

        # -------------------------------------------------------------------
        # Display
        # -------------------------------------------------------------------

        Clear-Host

        Write-Host "=== REAL-TIME IPv4 vs IPv6 TRAFFIC MONITOR ===" `
            -ForegroundColor Yellow

        Write-Host "Scope: Windows host traffic across all active IP interfaces"

        Write-Host "Measurement: actual observed packet sizes via pktmon"

        Write-Host (
            "Addresses: IPv4 [{0}]  IPv6 [{1}]" -f `
                $ipv4Addresses.Count,
                $ipv6Addresses.Count
        ) -ForegroundColor DarkGray

        Write-Host "Controls: [P] Pause/Resume   [Q] Quit   [Ctrl+C] Quit`n" `
            -ForegroundColor DarkGray

        Write-Host "--- REAL-TIME SPEEDS ---" -ForegroundColor Cyan

        Write-Host (
            "IPv4 Download: {0,10} KB/s  |  IPv4 Upload: {1,10} KB/s" -f `
                $v4InSpeed,
                $v4OutSpeed
        ) -ForegroundColor Green

        Write-Host (
            "IPv6 Download: {0,10} KB/s  |  IPv6 Upload: {1,10} KB/s" -f `
                $v6InSpeed,
                $v6OutSpeed
        ) -ForegroundColor Magenta

        if ($sampleTotal -gt 0) {

            Write-Host (
                "Real-Time Split: IPv4 [{0}%]  vs  IPv6 [{1}%]" -f `
                    $v4RealtimePct,
                    $v6RealtimePct
            ) -ForegroundColor DarkGray
        }
        else {
            Write-Host "Real-Time Split: [Idle]" `
                -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "--- TOTAL ACCUMULATED TRANSFERS (THIS SESSION) ---" `
            -ForegroundColor Cyan

        Write-Host (
            "IPv4 Download: {0,10} MB    |  IPv4 Upload: {1,10} MB" -f `
                $v4InMB,
                $v4OutMB
        ) -ForegroundColor Green

        Write-Host (
            "IPv6 Download: {0,10} MB    |  IPv6 Upload: {1,10} MB" -f `
                $v6InMB,
                $v6OutMB
        ) -ForegroundColor Magenta

        if ($totalTraffic -gt 0) {

            Write-Host (
                "Overall Split:   IPv4 [{0}%]  vs  IPv6 [{1}%]" -f `
                    $v4TotalPct,
                    $v6TotalPct
            ) -ForegroundColor Yellow
        }
        else {
            Write-Host "Overall Split:   [No Data Yet]" `
                -ForegroundColor DarkGray
        }

        # Start a fresh real-time sample.
        $sampleV4In  = 0
        $sampleV4Out = 0
        $sampleV6In  = 0
        $sampleV6Out = 0

        $lastDisplay = $now
    }
}
finally {

    Write-Host "`nStopping capture..." -ForegroundColor DarkGray

    if ($null -ne $captureJob) {
        Stop-Job -Job $captureJob -ErrorAction SilentlyContinue
        Remove-Job -Job $captureJob -Force -ErrorAction SilentlyContinue
    }

    try {
        & pktmon stop 2>$null | Out-Null
    } catch {
    }

    try {
        & pktmon filter remove 2>$null | Out-Null
    } catch {
    }

    Write-Host "Done." -ForegroundColor Green
}