param(
    [string]$InterfaceName = "Wi-Fi",
    [int]$WindowSeconds = 5,
    [int]$Top = 10,
    [switch]$ResolveNames
)

$ErrorActionPreference = 'Stop'

$tshark = "C:\Program Files\Wireshark\tshark.exe"

if (-not (Test-Path $tshark)) {
    Write-Host "TShark not found: $tshark" -ForegroundColor Red
    exit 1
}

# ============================================================================
# REMOTE TRAFFIC TALKERS
#
# Shows:
#
#   - IPv4 vs IPv6 traffic
#   - Session download/upload totals
#   - Overall IPv4/IPv6 split
#   - Top remote endpoints
#   - Remote port
#   - TCP / UDP / QUIC transport
#   - RX / TX / total bytes
#   - Average transfer rate during capture window
#   - Optional reverse DNS hostname lookup
#
# Examples:
#
#   .\talkers.ps1
#
#   .\talkers.ps1 -WindowSeconds 10 -Top 20
#
#   .\talkers.ps1 -WindowSeconds 10 -Top 20 -ResolveNames
#
# Requires:
#
#   Wireshark / TShark
#   Npcap
#
# Ctrl+C quits.
# ============================================================================


# ---------------------------------------------------------------------------
# Find the interface in TShark.
# ---------------------------------------------------------------------------

$interfaces = & $tshark -D

$interfaceLine = $interfaces |
    Where-Object { $_ -like "*($InterfaceName)" } |
    Select-Object -First 1

if (-not $interfaceLine) {

    Write-Host "Could not find TShark interface: $InterfaceName" `
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
# Find IP addresses assigned to this host on the selected interface.
# ---------------------------------------------------------------------------

$ipv4Addresses = @(
    Get-NetIPAddress `
        -InterfaceAlias $InterfaceName `
        -AddressFamily IPv4 `
        -AddressState Preferred `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.IPAddress -ne '127.0.0.1' -and
        $_.IPAddress -notlike '169.254.*'
    } |
    Select-Object -ExpandProperty IPAddress -Unique
)

$ipv6Addresses = @(
    Get-NetIPAddress `
        -InterfaceAlias $InterfaceName `
        -AddressFamily IPv6 `
        -AddressState Preferred `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.IPAddress -ne '::1' -and
        $_.IPAddress -notlike 'fe80:*'
    } |
    Select-Object -ExpandProperty IPAddress -Unique
)

if (
    $ipv4Addresses.Count -eq 0 -and
    $ipv6Addresses.Count -eq 0
) {

    Write-Host "No usable IP addresses found on $InterfaceName." `
        -ForegroundColor Red

    exit 1
}


# ---------------------------------------------------------------------------
# Build a fast lookup set containing all local addresses.
# ---------------------------------------------------------------------------

$localAddresses =
    [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

foreach ($ip in $ipv4Addresses) {
    [void]$localAddresses.Add($ip)
}

foreach ($ip in $ipv6Addresses) {
    [void]$localAddresses.Add($ip)
}


# ---------------------------------------------------------------------------
# Session counters.
# ---------------------------------------------------------------------------

[long]$totalV4In  = 0
[long]$totalV4Out = 0
[long]$totalV6In  = 0
[long]$totalV6Out = 0


# ---------------------------------------------------------------------------
# Cache reverse DNS lookups.
# ---------------------------------------------------------------------------

$dnsCache = @{}


# ---------------------------------------------------------------------------
# Formatting helpers.
# ---------------------------------------------------------------------------

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


function Format-Speed {

    param(
        [double]$Bytes,
        [double]$Seconds
    )

    if ($Seconds -le 0) {
        return "0 B/s"
    }

    $speed = $Bytes / $Seconds

    if ($speed -ge 1GB) {
        return "{0:N2} GB/s" -f ($speed / 1GB)
    }

    if ($speed -ge 1MB) {
        return "{0:N2} MB/s" -f ($speed / 1MB)
    }

    if ($speed -ge 1KB) {
        return "{0:N1} KB/s" -f ($speed / 1KB)
    }

    return "{0:N0} B/s" -f $speed
}


function Resolve-RemoteName {

    param([string]$IPAddress)

    if (-not $ResolveNames) {
        return ""
    }

    if ($dnsCache.ContainsKey($IPAddress)) {
        return $dnsCache[$IPAddress]
    }

    try {
        $name =
            [System.Net.Dns]::GetHostEntry(
                $IPAddress
            ).HostName
    }
    catch {
        $name = ""
    }

    $dnsCache[$IPAddress] = $name

    return $name
}


# ---------------------------------------------------------------------------
# Initial display.
# ---------------------------------------------------------------------------

Write-Host "=== REMOTE TRAFFIC TALKERS ===" `
    -ForegroundColor Yellow

Write-Host "Interface: $InterfaceName"
Write-Host "TShark interface: $interfaceNumber"

Write-Host (
    "Local IPv4: {0}" -f (
        $ipv4Addresses -join ", "
    )
) -ForegroundColor DarkGray

Write-Host (
    "Local IPv6: {0}" -f (
        $ipv6Addresses -join ", "
    )
) -ForegroundColor DarkGray

Write-Host "Window: $WindowSeconds seconds"
Write-Host "Top: $Top"
Write-Host ""
Write-Host "Press Ctrl+C to quit." `
    -ForegroundColor DarkGray


# ===========================================================================
# Main capture loop.
# ===========================================================================

while ($true) {

    # -----------------------------------------------------------------------
    # Capture packet metadata.
    #
    # No payload is retained.
    #
    # frame.protocols gives us something similar to:
    #
    #   eth:ethertype:ip:tcp:tls
    #   eth:ethertype:ip:udp:quic
    #
    # That allows actual QUIC detection without assuming UDP/443 == QUIC.
    # -----------------------------------------------------------------------

    $output = @(
        & $tshark `
            -i $interfaceNumber `
            -n `
            -a "duration:$WindowSeconds" `
            -f "ip or ip6" `
            -T fields `
            -E occurrence=f `
            -e frame.len `
            -e ip.src `
            -e ip.dst `
            -e ipv6.src `
            -e ipv6.dst `
            -e tcp.srcport `
            -e tcp.dstport `
            -e udp.srcport `
            -e udp.dstport `
            -e frame.protocols
    )

    if ($LASTEXITCODE -ne 0) {

        Write-Host ""
        Write-Host (
            "TShark exited with code $LASTEXITCODE."
        ) -ForegroundColor Red

        break
    }


    # -----------------------------------------------------------------------
    # Current window counters.
    # -----------------------------------------------------------------------

    [long]$windowV4In  = 0
    [long]$windowV4Out = 0
    [long]$windowV6In  = 0
    [long]$windowV6Out = 0

    $talkers = @{}


    # -----------------------------------------------------------------------
    # Process packets.
    # -----------------------------------------------------------------------

    foreach ($line in $output) {

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        # Regex.Split preserves empty tab-separated fields, which matters
        # because IPv4 packets have empty IPv6 columns and vice versa.

        $parts = [regex]::Split(
            $line,
            "`t"
        )

        if ($parts.Count -lt 10) {
            continue
        }


        # -------------------------------------------------------------------
        # Extract TShark fields.
        # -------------------------------------------------------------------

        $lengthText = $parts[0]

        $ipv4Source = $parts[1]
        $ipv4Dest   = $parts[2]

        $ipv6Source = $parts[3]
        $ipv6Dest   = $parts[4]

        $tcpSourcePort = $parts[5]
        $tcpDestPort   = $parts[6]

        $udpSourcePort = $parts[7]
        $udpDestPort   = $parts[8]

        $protocolStack = $parts[9]


        # -------------------------------------------------------------------
        # Frame length.
        # -------------------------------------------------------------------

        [long]$length = 0

        if (
            -not [long]::TryParse(
                $lengthText,
                [ref]$length
            )
        ) {
            continue
        }


        # -------------------------------------------------------------------
        # Determine IP family.
        # -------------------------------------------------------------------

        $family = $null
        $source = $null
        $destination = $null

        if ($ipv4Source -and $ipv4Dest) {

            $family = "IPv4"
            $source = $ipv4Source
            $destination = $ipv4Dest
        }
        elseif ($ipv6Source -and $ipv6Dest) {

            $family = "IPv6"
            $source = $ipv6Source
            $destination = $ipv6Dest
        }
        else {
            continue
        }


        # -------------------------------------------------------------------
        # Determine whether packet is RX or TX relative to this machine.
        # -------------------------------------------------------------------

        $remote = $null
        $direction = $null

        if ($localAddresses.Contains($source)) {

            $remote = $destination
            $direction = "TX"
        }
        elseif ($localAddresses.Contains($destination)) {

            $remote = $source
            $direction = "RX"
        }
        else {

            # Packet does not directly belong to this host.
            continue
        }


        # -------------------------------------------------------------------
        # Update IPv4/IPv6 window and session counters.
        # -------------------------------------------------------------------

        if ($family -eq "IPv4") {

            if ($direction -eq "RX") {

                $windowV4In += $length
                $totalV4In += $length
            }
            else {

                $windowV4Out += $length
                $totalV4Out += $length
            }
        }
        else {

            if ($direction -eq "RX") {

                $windowV6In += $length
                $totalV6In += $length
            }
            else {

                $windowV6Out += $length
                $totalV6Out += $length
            }
        }


        # -------------------------------------------------------------------
        # Determine transport and REMOTE port.
        #
        # TX:
        #
        #   destination port = remote port
        #
        # RX:
        #
        #   source port = remote port
        # -------------------------------------------------------------------

        $transport = "Other"
        $remotePort = "-"

        if ($tcpSourcePort -or $tcpDestPort) {

            $transport = "TCP"

            if ($direction -eq "TX") {
                $remotePort = $tcpDestPort
            }
            else {
                $remotePort = $tcpSourcePort
            }
        }
        elseif ($udpSourcePort -or $udpDestPort) {

            $transport = "UDP"

            if ($direction -eq "TX") {
                $remotePort = $udpDestPort
            }
            else {
                $remotePort = $udpSourcePort
            }

            # Use TShark's actual protocol decoding.
            if (
                $protocolStack -match '(^|:)quic(:|$)'
            ) {
                $transport = "QUIC"
            }
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $remotePort
            )
        ) {
            $remotePort = "-"
        }


        # -------------------------------------------------------------------
        # Aggregate by:
        #
        #   family + remote IP + remote port + transport
        #
        # This means:
        #
        #   1.2.3.4:443 TCP
        #
        # and
        #
        #   1.2.3.4:443 QUIC
        #
        # remain separate rows.
        # -------------------------------------------------------------------

        $key =
            "$family|$remote|$remotePort|$transport"

        if (-not $talkers.ContainsKey($key)) {

            $talkers[$key] = [PSCustomObject]@{
                Family    = $family
                Remote    = $remote
                Port      = $remotePort
                Transport = $transport
                RX        = [long]0
                TX        = [long]0
            }
        }

        if ($direction -eq "RX") {
            $talkers[$key].RX += $length
        }
        else {
            $talkers[$key].TX += $length
        }
    }


    # =======================================================================
    # Calculate totals.
    # =======================================================================

    $windowV4 =
        $windowV4In +
        $windowV4Out

    $windowV6 =
        $windowV6In +
        $windowV6Out

    $windowTotal =
        $windowV4 +
        $windowV6


    if ($windowTotal -gt 0) {

        $windowV4Pct = [math]::Round(
            ($windowV4 / $windowTotal) * 100
        )

        $windowV6Pct =
            100 - $windowV4Pct
    }
    else {

        $windowV4Pct = 0
        $windowV6Pct = 0
    }


    $sessionV4 =
        $totalV4In +
        $totalV4Out

    $sessionV6 =
        $totalV6In +
        $totalV6Out

    $sessionTotal =
        $sessionV4 +
        $sessionV6


    if ($sessionTotal -gt 0) {

        $sessionV4Pct = [math]::Round(
            ($sessionV4 / $sessionTotal) * 100
        )

        $sessionV6Pct =
            100 - $sessionV4Pct
    }
    else {

        $sessionV4Pct = 0
        $sessionV6Pct = 0
    }


    # =======================================================================
    # Display.
    # =======================================================================

    Clear-Host

    Write-Host "=== REMOTE TRAFFIC TALKERS ===" `
        -ForegroundColor Yellow

    Write-Host "Interface: $InterfaceName"
    Write-Host "TShark interface: $interfaceNumber"
    Write-Host "Capture window: $WindowSeconds seconds"

    Write-Host ""


    # -----------------------------------------------------------------------
    # Session totals.
    # -----------------------------------------------------------------------

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
                $sessionV4Pct,
                $sessionV6Pct
        ) -ForegroundColor Yellow
    }
    else {

        Write-Host "Overall Split: [No Data Yet]" `
            -ForegroundColor DarkGray
    }


    Write-Host ""


    # -----------------------------------------------------------------------
    # Current capture window.
    # -----------------------------------------------------------------------

    Write-Host (
        "--- CURRENT {0} SECOND WINDOW ---" -f `
            $WindowSeconds
    ) -ForegroundColor Cyan

    Write-Host (
        "IPv4 Download: {0,14} | IPv4 Upload: {1,14}" -f `
            (Format-Bytes $windowV4In),
            (Format-Bytes $windowV4Out)
    ) -ForegroundColor Green

    Write-Host (
        "IPv6 Download: {0,14} | IPv6 Upload: {1,14}" -f `
            (Format-Bytes $windowV6In),
            (Format-Bytes $windowV6Out)
    ) -ForegroundColor Magenta

    if ($windowTotal -gt 0) {

        Write-Host (
            "Window Split:    IPv4 [{0}%] vs IPv6 [{1}%]" -f `
                $windowV4Pct,
                $windowV6Pct
        ) -ForegroundColor DarkGray
    }
    else {

        Write-Host "Window Split: [Idle]" `
            -ForegroundColor DarkGray
    }


    Write-Host ""


    # -----------------------------------------------------------------------
    # Top talkers.
    # -----------------------------------------------------------------------

    $topTalkers = @(
        $talkers.Values |
        Sort-Object {
            $_.RX + $_.TX
        } -Descending |
        Select-Object -First $Top
    )

    Write-Host "--- TOP REMOTE ENDPOINTS ---" `
        -ForegroundColor Cyan

    if ($topTalkers.Count -eq 0) {

        Write-Host "No matching traffic captured." `
            -ForegroundColor DarkGray

        Write-Host ""

        continue
    }


    Write-Host (
        "{0,-5} {1,-39} {2,7} {3,-9} {4,11} {5,11} {6,11} {7,12}  {8}" -f `
            "Proto",
            "Remote",
            "Port",
            "Transport",
            "RX",
            "TX",
            "Total",
            "Average",
            "Hostname"
    ) -ForegroundColor DarkGray


    Write-Host (
        "{0,-5} {1,-39} {2,7} {3,-9} {4,11} {5,11} {6,11} {7,12}  {8}" -f `
            "-----",
            "---------------------------------------",
            "-------",
            "---------",
            "-----------",
            "-----------",
            "-----------",
            "------------",
            "--------"
    ) -ForegroundColor DarkGray


    foreach ($talker in $topTalkers) {

        $total =
            $talker.RX +
            $talker.TX

        $hostname =
            Resolve-RemoteName `
                $talker.Remote

        $color =
            if ($talker.Family -eq "IPv6") {
                "Magenta"
            }
            else {
                "Green"
            }


        Write-Host (
            "{0,-5} {1,-39} {2,7} {3,-9} {4,11} {5,11} {6,11} {7,12}  {8}" -f `
                $talker.Family,
                $talker.Remote,
                $talker.Port,
                $talker.Transport,
                (Format-Bytes $talker.RX),
                (Format-Bytes $talker.TX),
                (Format-Bytes $total),
                (Format-Speed $total $WindowSeconds),
                $hostname
        ) -ForegroundColor $color
    }


    Write-Host ""

    Write-Host (
        "Next capture window starting... Ctrl+C to quit."
    ) -ForegroundColor DarkGray
}