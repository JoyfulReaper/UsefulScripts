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
# Continuous TShark capture.
#
# Shows:
#
#   - IPv4 vs IPv6 traffic
#   - Session download/upload totals
#   - Overall IPv4/IPv6 split
#   - Current capture window totals
#   - Top remote endpoints
#   - Remote port
#   - TCP / UDP / QUIC transport
#   - RX / TX / total bytes
#   - Average transfer rate
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
# Find TShark interface.
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
# Find local IP addresses.
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
# Fast lookup for local addresses.
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
# State.
# ---------------------------------------------------------------------------

$session = @{
    V4In  = [long]0
    V4Out = [long]0
    V6In  = [long]0
    V6Out = [long]0
}

$window = @{
    V4In  = [long]0
    V4Out = [long]0
    V6In  = [long]0
    V6Out = [long]0
}

$talkers = @{}

# Contains either a DNS Task or a resolved hostname string.
$dnsCache = @{}


# ---------------------------------------------------------------------------
# Formatting.
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


# ---------------------------------------------------------------------------
# Non-blocking reverse DNS.
#
# First time an IP appears:
#
#   start DNS lookup
#   immediately return "(resolving)"
#
# Later redraw:
#
#   if task finished, cache/display result
#
# This prevents DNS from stopping packet consumption.
# ---------------------------------------------------------------------------

function Get-RemoteName {

    param([string]$IPAddress)

    if (-not $ResolveNames) {
        return ""
    }

    if (-not $dnsCache.ContainsKey($IPAddress)) {

        try {
            $dnsCache[$IPAddress] =
                [System.Net.Dns]::GetHostEntryAsync(
                    $IPAddress
                )
        }
        catch {
            $dnsCache[$IPAddress] = ""
            return ""
        }

        return "(resolving)"
    }

    $entry = $dnsCache[$IPAddress]

    if ($entry -is [string]) {
        return $entry
    }

    if ($entry.IsCompletedSuccessfully) {

        try {
            $name = $entry.Result.HostName
        }
        catch {
            $name = ""
        }

        $dnsCache[$IPAddress] = $name

        return $name
    }

    if (
        $entry.IsFaulted -or
        $entry.IsCanceled
    ) {

        $dnsCache[$IPAddress] = ""

        return ""
    }

    return "(resolving)"
}


# ---------------------------------------------------------------------------
# Process one TShark packet line.
# ---------------------------------------------------------------------------

function Process-CaptureLine {

    param(
        [string]$Line,
        $LocalAddresses,
        [hashtable]$Session,
        [hashtable]$Window,
        [hashtable]$Talkers
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return
    }

    $parts = [regex]::Split(
        $Line,
        "`t"
    )

    if ($parts.Count -lt 10) {
        return
    }


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


    [long]$length = 0

    if (
        -not [long]::TryParse(
            $lengthText,
            [ref]$length
        )
    ) {
        return
    }


    # -----------------------------------------------------------------------
    # IP family.
    # -----------------------------------------------------------------------

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
        return
    }


    # -----------------------------------------------------------------------
    # RX / TX direction.
    # -----------------------------------------------------------------------

    $remote = $null
    $direction = $null

    if ($LocalAddresses.Contains($source)) {

        $remote = $destination
        $direction = "TX"
    }
    elseif ($LocalAddresses.Contains($destination)) {

        $remote = $source
        $direction = "RX"
    }
    else {

        return
    }


    # -----------------------------------------------------------------------
    # Traffic counters.
    # -----------------------------------------------------------------------

    if ($family -eq "IPv4") {

        if ($direction -eq "RX") {

            $Window.V4In += $length
            $Session.V4In += $length
        }
        else {

            $Window.V4Out += $length
            $Session.V4Out += $length
        }
    }
    else {

        if ($direction -eq "RX") {

            $Window.V6In += $length
            $Session.V6In += $length
        }
        else {

            $Window.V6Out += $length
            $Session.V6Out += $length
        }
    }


    # -----------------------------------------------------------------------
    # Transport + remote port.
    # -----------------------------------------------------------------------

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

        if (
            $protocolStack -match '(^|:)quic(:|$)'
        ) {
            $transport = "QUIC"
        }
    }

    if ([string]::IsNullOrWhiteSpace($remotePort)) {
        $remotePort = "-"
    }


    # -----------------------------------------------------------------------
    # Aggregate endpoint.
    # -----------------------------------------------------------------------

    $key =
        "$family|$remote|$remotePort|$transport"

    if (-not $Talkers.ContainsKey($key)) {

        $Talkers[$key] = [PSCustomObject]@{
            Family    = $family
            Remote    = $remote
            Port      = $remotePort
            Transport = $transport
            RX        = [long]0
            TX        = [long]0
        }
    }

    if ($direction -eq "RX") {
        $Talkers[$key].RX += $length
    }
    else {
        $Talkers[$key].TX += $length
    }
}


# ---------------------------------------------------------------------------
# Dashboard.
# ---------------------------------------------------------------------------

function Show-Dashboard {

    param(
        [hashtable]$Session,
        [hashtable]$Window,
        [hashtable]$Talkers,
        [double]$ActualWindowSeconds
    )

    $windowV4 =
        $Window.V4In +
        $Window.V4Out

    $windowV6 =
        $Window.V6In +
        $Window.V6Out

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
        $Session.V4In +
        $Session.V4Out

    $sessionV6 =
        $Session.V6In +
        $Session.V6Out

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


    Clear-Host


    Write-Host "=== REMOTE TRAFFIC TALKERS ===" `
        -ForegroundColor Yellow

    Write-Host "Interface: $InterfaceName"
    Write-Host "TShark interface: $interfaceNumber"

    Write-Host (
        "Capture mode: continuous | Display window: {0:N1} sec" -f `
            $ActualWindowSeconds
    )

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

    Write-Host ""


    # -----------------------------------------------------------------------
    # Session totals.
    # -----------------------------------------------------------------------

    Write-Host "--- TOTAL CAPTURED THIS SESSION ---" `
        -ForegroundColor Cyan

    Write-Host (
        "IPv4 Download: {0,14} | IPv4 Upload: {1,14}" -f `
            (Format-Bytes $Session.V4In),
            (Format-Bytes $Session.V4Out)
    ) -ForegroundColor Green

    Write-Host (
        "IPv6 Download: {0,14} | IPv6 Upload: {1,14}" -f `
            (Format-Bytes $Session.V6In),
            (Format-Bytes $Session.V6Out)
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
    # Window totals.
    # -----------------------------------------------------------------------

    Write-Host (
        "--- CURRENT {0:N1} SECOND WINDOW ---" -f `
            $ActualWindowSeconds
    ) -ForegroundColor Cyan

    Write-Host (
        "IPv4 Download: {0,14} | IPv4 Upload: {1,14}" -f `
            (Format-Bytes $Window.V4In),
            (Format-Bytes $Window.V4Out)
    ) -ForegroundColor Green

    Write-Host (
        "IPv6 Download: {0,14} | IPv6 Upload: {1,14}" -f `
            (Format-Bytes $Window.V6In),
            (Format-Bytes $Window.V6Out)
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
    # Talkers.
    # -----------------------------------------------------------------------

    $topTalkers = @(
        $Talkers.Values |
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

        return
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
            Get-RemoteName `
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
                (Format-Speed $total $ActualWindowSeconds),
                $hostname
        ) -ForegroundColor $color
    }


    Write-Host ""

    Write-Host (
        "TShark capture remains running continuously. Ctrl+C to quit."
    ) -ForegroundColor DarkGray
}


# ============================================================================
# Start ONE persistent TShark process.
# ============================================================================

$startInfo =
    [System.Diagnostics.ProcessStartInfo]::new()

$startInfo.FileName = $tshark
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.CreateNoWindow = $true


# -l makes TShark flush packet output continuously.

$tsharkArguments = @(
    "-i", "$interfaceNumber",
    "-n",
    "-l",
    "-f", "ip or ip6",
    "-T", "fields",
    "-E", "occurrence=f",
    "-e", "frame.len",
    "-e", "ip.src",
    "-e", "ip.dst",
    "-e", "ipv6.src",
    "-e", "ipv6.dst",
    "-e", "tcp.srcport",
    "-e", "tcp.dstport",
    "-e", "udp.srcport",
    "-e", "udp.dstport",
    "-e", "frame.protocols"
)

foreach ($argument in $tsharkArguments) {
    [void]$startInfo.ArgumentList.Add($argument)
}


$process =
    [System.Diagnostics.Process]::new()

$process.StartInfo = $startInfo


Write-Host ""
Write-Host "Starting continuous TShark capture..." `
    -ForegroundColor DarkGray


if (-not $process.Start()) {

    Write-Host "Could not start TShark." `
        -ForegroundColor Red

    exit 1
}


# Drain stderr asynchronously so its pipe can never fill and block TShark.
$stderrTask =
    $process.StandardError.ReadToEndAsync()


# ---------------------------------------------------------------------------
# Window timing.
# ---------------------------------------------------------------------------

$windowStartedAt =
    [DateTimeOffset]::UtcNow

$nextWindowAt =
    $windowStartedAt.AddSeconds(
        $WindowSeconds
    )

$readTask = $null

$unexpectedExit = $false
$exitCode = $null
$stderrText = ""


try {

    while ($true) {

        if ($process.HasExited) {

            $unexpectedExit = $true
            $exitCode = $process.ExitCode

            break
        }


        # -------------------------------------------------------------------
        # Always keep one asynchronous stdout read pending.
        #
        # We wait at most 200ms for a packet. This means that even if the
        # network is completely idle, the dashboard window can still expire
        # and redraw on time.
        # -------------------------------------------------------------------

        if ($null -eq $readTask) {

            $readTask =
                $process.StandardOutput.ReadLineAsync()
        }


        $now =
            [DateTimeOffset]::UtcNow

        $millisecondsUntilWindow =
            ($nextWindowAt - $now).TotalMilliseconds

        $waitMilliseconds =
            [int][math]::Max(
                1,
                [math]::Min(
                    200,
                    $millisecondsUntilWindow
                )
            )


        if ($readTask.Wait($waitMilliseconds)) {

            $line =
                $readTask.Result

            $readTask = $null


            # Null means stdout was closed.
            if ($null -eq $line) {

                if ($process.HasExited) {

                    $unexpectedExit = $true
                    $exitCode = $process.ExitCode
                }

                break
            }


            Process-CaptureLine `
                -Line $line `
                -LocalAddresses $localAddresses `
                -Session $session `
                -Window $window `
                -Talkers $talkers
        }


        # -------------------------------------------------------------------
        # Display interval expired.
        #
        # Important:
        #
        # We are NOT stopping TShark here.
        #
        # TShark remains alive and continues feeding stdout while we reset
        # the PowerShell-side window counters.
        # -------------------------------------------------------------------

        $now =
            [DateTimeOffset]::UtcNow


        if ($now -ge $nextWindowAt) {

            $actualWindowSeconds =
                ($now - $windowStartedAt).TotalSeconds

            if ($actualWindowSeconds -le 0) {
                $actualWindowSeconds = $WindowSeconds
            }


            Show-Dashboard `
                -Session $session `
                -Window $window `
                -Talkers $talkers `
                -ActualWindowSeconds $actualWindowSeconds


            # New reporting window.
            #
            # Session counters remain untouched.

            $window = @{
                V4In  = [long]0
                V4Out = [long]0
                V6In  = [long]0
                V6Out = [long]0
            }

            $talkers = @{}


            $windowStartedAt =
                [DateTimeOffset]::UtcNow

            $nextWindowAt =
                $windowStartedAt.AddSeconds(
                    $WindowSeconds
                )
        }
    }
}
finally {

    if (-not $process.HasExited) {

        try {
            $process.Kill($true)
        }
        catch {
        }

        try {
            $process.WaitForExit()
        }
        catch {
        }
    }


    try {

        if ($stderrTask.IsCompleted) {
            $stderrText = $stderrTask.Result
        }
    }
    catch {
    }


    $process.Dispose()
}


if ($unexpectedExit) {

    Write-Host ""
    Write-Host (
        "TShark exited unexpectedly with code $exitCode."
    ) -ForegroundColor Red

    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {

        Write-Host ""
        Write-Host $stderrText `
            -ForegroundColor DarkGray
    }
}