$ErrorActionPreference = 'Stop'

# ============================================================================
# IPv4 vs IPv6 Traffic Monitor
#
# Requires:
#   Wireshark / TShark
#   Npcap
#
# Controls:
#   P = Pause/resume display
#   Q = Quit
#
# NOTE:
# Each measurement is a fresh ~1 second TShark capture.
# This avoids the giant delayed PowerShell packet-processing backlog.
# ============================================================================

$tshark = "C:\Program Files\Wireshark\tshark.exe"
$interfaceName = "vEthernet (LAN-External)"

if (-not (Test-Path $tshark)) {
    Write-Host "TShark not found: $tshark" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Find TShark interface number dynamically.
# ---------------------------------------------------------------------------

$interfaces = & $tshark -D

$interfaceLine = $interfaces |
    Where-Object { $_ -like "*($interfaceName)" } |
    Select-Object -First 1

if (-not $interfaceLine) {
    Write-Host "Could not find TShark interface: $interfaceName" `
        -ForegroundColor Red

    Write-Host ""
    $interfaces
    exit 1
}

if ($interfaceLine -notmatch '^\s*(\d+)\.') {
    Write-Host "Could not determine TShark interface number." `
        -ForegroundColor Red
    exit 1
}

$interfaceNumber = [int]$Matches[1]

# ---------------------------------------------------------------------------
# Get the IP addresses actually assigned to this Windows host on that
# interface.
# ---------------------------------------------------------------------------

$ipv4Addresses = @(
    Get-NetIPAddress `
        -InterfaceAlias $interfaceName `
        -AddressFamily IPv4 `
        -AddressState Preferred |
    Where-Object {
        $_.IPAddress -ne '127.0.0.1' -and
        $_.IPAddress -notlike '169.254.*'
    } |
    Select-Object -ExpandProperty IPAddress -Unique
)

$ipv6Addresses = @(
    Get-NetIPAddress `
        -InterfaceAlias $interfaceName `
        -AddressFamily IPv6 `
        -AddressState Preferred |
    Where-Object {
        $_.IPAddress -ne '::1' -and
        $_.IPAddress -notlike 'fe80:*'
    } |
    Select-Object -ExpandProperty IPAddress -Unique
)

if ($ipv4Addresses.Count -eq 0) {
    Write-Host "No IPv4 address found on $interfaceName." `
        -ForegroundColor Red
    exit 1
}

if ($ipv6Addresses.Count -eq 0) {
    Write-Host "No global IPv6 address found on $interfaceName." `
        -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Build Wireshark display filters for inbound/outbound traffic.
# ---------------------------------------------------------------------------

$v4InParts = @(
    foreach ($ip in $ipv4Addresses) {
        "ip.dst == $ip"
    }
)

$v4OutParts = @(
    foreach ($ip in $ipv4Addresses) {
        "ip.src == $ip"
    }
)

$v6InParts = @(
    foreach ($ip in $ipv6Addresses) {
        "ipv6.dst == $ip"
    }
)

$v6OutParts = @(
    foreach ($ip in $ipv6Addresses) {
        "ipv6.src == $ip"
    }
)

$v4InFilter  = "(" + ($v4InParts -join " || ") + ")"
$v4OutFilter = "(" + ($v4OutParts -join " || ") + ")"
$v6InFilter  = "(" + ($v6InParts -join " || ") + ")"
$v6OutFilter = "(" + ($v6OutParts -join " || ") + ")"

# TShark will return four byte counters:
#
#   1 IPv4 RX
#   2 IPv4 TX
#   3 IPv6 RX
#   4 IPv6 TX
#
# BYTES() tells TShark to do the byte summing internally.

$ioStat = "io,stat,1," +
          "BYTES()$v4InFilter," +
          "BYTES()$v4OutFilter," +
          "BYTES()$v6InFilter," +
          "BYTES()$v6OutFilter"

# ---------------------------------------------------------------------------
# Session counters.
# ---------------------------------------------------------------------------

[long]$totalV4In  = 0
[long]$totalV4Out = 0
[long]$totalV6In  = 0
[long]$totalV6Out = 0

$paused = $false

function Format-Speed {
    param([double]$BytesPerSecond)

    if ($BytesPerSecond -ge 1MB) {
        return "{0:N2} MB/s" -f ($BytesPerSecond / 1MB)
    }

    if ($BytesPerSecond -ge 1KB) {
        return "{0:N1} KB/s" -f ($BytesPerSecond / 1KB)
    }

    return "{0:N0} B/s" -f $BytesPerSecond
}

function Format-Bytes {
    param([double]$Bytes)

    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }

    if ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }

    if ($Bytes -ge 1KB) {
        return "{0:N1} KB" -f ($Bytes / 1KB)
    }

    return "{0:N0} B" -f $Bytes
}

:monitor while ($true) {

    # -----------------------------------------------------------------------
    # Capture approximately one second.
    #
    # TShark performs the packet capture, filtering and byte aggregation.
    # PowerShell only receives the finished statistics table.
    # -----------------------------------------------------------------------

    $output = @(
        & $tshark `
            -i $interfaceNumber `
            -n `
            -q `
            -a duration:1 `
            -f "ip or ip6" `
            -z $ioStat 2>$null
    )

    # Get actual capture duration.
    $duration = 1.0

    foreach ($line in $output) {
        if ($line -match 'Duration:\s+([0-9.]+)\s+secs') {
            $duration = [double]$Matches[1]
            break
        }
    }

    if ($duration -le 0) {
        $duration = 1.0
    }

    # TShark can produce more than one interval row if the capture runs
    # slightly over one second, so sum every statistics row.

    [long]$v4InBytes  = 0
    [long]$v4OutBytes = 0
    [long]$v6InBytes  = 0
    [long]$v6OutBytes = 0

    foreach ($line in $output) {

        if ($line -notmatch '<>') {
            continue
        }

        $parts = @(
            $line.Split('|') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' }
        )

        # Interval + four BYTES columns
        if ($parts.Count -lt 5) {
            continue
        }

        if (
            $parts[1] -match '^\d+$' -and
            $parts[2] -match '^\d+$' -and
            $parts[3] -match '^\d+$' -and
            $parts[4] -match '^\d+$'
        ) {
            $v4InBytes  += [long]$parts[1]
            $v4OutBytes += [long]$parts[2]
            $v6InBytes  += [long]$parts[3]
            $v6OutBytes += [long]$parts[4]
        }
    }

    # -----------------------------------------------------------------------
    # Accumulate session totals.
    # -----------------------------------------------------------------------

    $totalV4In  += $v4InBytes
    $totalV4Out += $v4OutBytes
    $totalV6In  += $v6InBytes
    $totalV6Out += $v6OutBytes

    # -----------------------------------------------------------------------
    # Speeds.
    # -----------------------------------------------------------------------

    $v4InSpeed  = $v4InBytes  / $duration
    $v4OutSpeed = $v4OutBytes / $duration
    $v6InSpeed  = $v6InBytes  / $duration
    $v6OutSpeed = $v6OutBytes / $duration

    $currentV4 = $v4InBytes + $v4OutBytes
    $currentV6 = $v6InBytes + $v6OutBytes
    $currentTotal = $currentV4 + $currentV6

    if ($currentTotal -gt 0) {
        $v4CurrentPct = [math]::Round(
            ($currentV4 / $currentTotal) * 100
        )

        $v6CurrentPct = 100 - $v4CurrentPct
    }
    else {
        $v4CurrentPct = 0
        $v6CurrentPct = 0
    }

    $sessionV4 = $totalV4In + $totalV4Out
    $sessionV6 = $totalV6In + $totalV6Out
    $sessionTotal = $sessionV4 + $sessionV6

    if ($sessionTotal -gt 0) {
        $v4SessionPct = [math]::Round(
            ($sessionV4 / $sessionTotal) * 100
        )

        $v6SessionPct = 100 - $v4SessionPct
    }
    else {
        $v4SessionPct = 0
        $v6SessionPct = 0
    }

    # -----------------------------------------------------------------------
    # Keyboard.
    # -----------------------------------------------------------------------

    while ([Console]::KeyAvailable) {

        $key = [Console]::ReadKey($true)

        switch ($key.Key) {

            'P' {
                $paused = -not $paused

                if ($paused) {
                    Write-Host ""
                    Write-Host (
                        "=== PAUSED - copy away. Press P to resume ==="
                    ) -ForegroundColor Yellow
                }
            }

            'Q' {
                break monitor
            }
        }
    }

    # Still capture/count while paused; just don't redraw.
    if ($paused) {
        continue
    }

    # -----------------------------------------------------------------------
    # Dashboard.
    # -----------------------------------------------------------------------

    Clear-Host

    Write-Host "=== IPv4 vs IPv6 TRAFFIC MONITOR ===" `
        -ForegroundColor Yellow

    Write-Host "Interface: $interfaceName"
    Write-Host "TShark interface: $interfaceNumber"

    Write-Host (
        "Local IPv4: {0}" -f ($ipv4Addresses -join ", ")
    ) -ForegroundColor DarkGray

    Write-Host (
        "Local IPv6: {0}" -f ($ipv6Addresses -join ", ")
    ) -ForegroundColor DarkGray

    Write-Host "Controls: [P] Pause display   [Q] Quit`n" `
        -ForegroundColor DarkGray

    Write-Host "--- REAL-TIME SPEEDS ---" `
        -ForegroundColor Cyan

    Write-Host (
        "IPv4 Download: {0,14} | IPv4 Upload: {1,14}" -f `
            (Format-Speed $v4InSpeed),
            (Format-Speed $v4OutSpeed)
    ) -ForegroundColor Green

    Write-Host (
        "IPv6 Download: {0,14} | IPv6 Upload: {1,14}" -f `
            (Format-Speed $v6InSpeed),
            (Format-Speed $v6OutSpeed)
    ) -ForegroundColor Magenta

    if ($currentTotal -gt 0) {
        Write-Host (
            "Real-Time Split: IPv4 [{0}%] vs IPv6 [{1}%]" -f `
                $v4CurrentPct,
                $v6CurrentPct
        ) -ForegroundColor DarkGray
    }
    else {
        Write-Host "Real-Time Split: [Idle]" `
            -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "--- TOTAL CAPTURED THIS SESSION ---" `
        -ForegroundColor Cyan

    Write-Host (
        "IPv4 Download: {0,14} | IPv4 Upload: {1,14}" -f `
            (Format-Bytes $totalV4In),
            (Format-Bytes $totalV4Out)
    ) -ForegroundColor Green

    Write-Host (
        "IPv6 Download: {0,14} | IPv6 Upload: {1,14}" -f `
            (Format-Bytes $totalV6In),
            (Format-Bytes $totalV6Out)
    ) -ForegroundColor Magenta

    if ($sessionTotal -gt 0) {
        Write-Host (
            "Overall Split:   IPv4 [{0}%] vs IPv6 [{1}%]" -f `
                $v4SessionPct,
                $v6SessionPct
        ) -ForegroundColor Yellow
    }
    else {
        Write-Host "Overall Split: [No Data Yet]" `
            -ForegroundColor DarkGray
    }
}