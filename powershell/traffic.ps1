$ErrorActionPreference = 'Stop'

# ============================================================================
# IPv4 vs IPv6 Traffic Monitor
#
# CONTINUOUS CAPTURE VERSION
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
# TShark is started ONCE and remains running continuously.
# PowerShell consumes packet metadata as it arrives and rolls the real-time
# counters approximately once per second.
#
# Pausing only pauses the screen redraw. Capture and session totals continue.
# ============================================================================

$tshark = "C:\Program Files\Wireshark\tshark.exe"
$interfaceName = "Wi-Fi"
$windowSeconds = 1.0

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
# Get addresses assigned to this host on the selected interface.
# ---------------------------------------------------------------------------

$ipv4Addresses = @(
    Get-NetIPAddress `
        -InterfaceAlias $interfaceName `
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
        -InterfaceAlias $interfaceName `
        -AddressFamily IPv6 `
        -AddressState Preferred `
        -ErrorAction SilentlyContinue |
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
# Fast lookup containing all local addresses.
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

$session = @{
    V4In  = [long]0
    V4Out = [long]0
    V6In  = [long]0
    V6Out = [long]0
}


# ---------------------------------------------------------------------------
# Current one-second window counters.
# ---------------------------------------------------------------------------

$window = @{
    V4In  = [long]0
    V4Out = [long]0
    V6In  = [long]0
    V6Out = [long]0
}

$paused = $false


# ---------------------------------------------------------------------------
# Formatting helpers.
# ---------------------------------------------------------------------------

function Format-Speed {

    param([double]$BytesPerSecond)

    if ($BytesPerSecond -ge 1GB) {
        return "{0:N2} GB/s" -f ($BytesPerSecond / 1GB)
    }

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


# ---------------------------------------------------------------------------
# Process one packet line emitted by TShark.
#
# Fields:
#
#   frame.len
#   ip.src
#   ip.dst
#   ipv6.src
#   ipv6.dst
#
# No packet payload is retained.
# ---------------------------------------------------------------------------

function Process-CaptureLine {

    param(
        [string]$Line,
        $LocalAddresses,
        [hashtable]$Session,
        [hashtable]$Window
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return
    }

    $parts = [regex]::Split(
        $Line,
        "`t"
    )

    if ($parts.Count -lt 5) {
        return
    }

    $lengthText = $parts[0]

    $ipv4Source = $parts[1]
    $ipv4Dest   = $parts[2]

    $ipv6Source = $parts[3]
    $ipv6Dest   = $parts[4]


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
    # IPv4.
    # -----------------------------------------------------------------------

    if ($ipv4Source -and $ipv4Dest) {

        if ($LocalAddresses.Contains($ipv4Source)) {

            $Window.V4Out += $length
            $Session.V4Out += $length

            return
        }

        if ($LocalAddresses.Contains($ipv4Dest)) {

            $Window.V4In += $length
            $Session.V4In += $length

            return
        }

        return
    }


    # -----------------------------------------------------------------------
    # IPv6.
    # -----------------------------------------------------------------------

    if ($ipv6Source -and $ipv6Dest) {

        if ($LocalAddresses.Contains($ipv6Source)) {

            $Window.V6Out += $length
            $Session.V6Out += $length

            return
        }

        if ($LocalAddresses.Contains($ipv6Dest)) {

            $Window.V6In += $length
            $Session.V6In += $length

            return
        }
    }
}


# ---------------------------------------------------------------------------
# Draw dashboard.
# ---------------------------------------------------------------------------

function Show-Dashboard {

    param(
        [hashtable]$Session,
        [hashtable]$Window,
        [double]$ActualWindowSeconds
    )

    if ($ActualWindowSeconds -le 0) {
        $ActualWindowSeconds = 1.0
    }


    # -----------------------------------------------------------------------
    # Real-time speeds.
    # -----------------------------------------------------------------------

    $v4InSpeed =
        $Window.V4In / $ActualWindowSeconds

    $v4OutSpeed =
        $Window.V4Out / $ActualWindowSeconds

    $v6InSpeed =
        $Window.V6In / $ActualWindowSeconds

    $v6OutSpeed =
        $Window.V6Out / $ActualWindowSeconds


    # -----------------------------------------------------------------------
    # Current split.
    # -----------------------------------------------------------------------

    $currentV4 =
        $Window.V4In +
        $Window.V4Out

    $currentV6 =
        $Window.V6In +
        $Window.V6Out

    $currentTotal =
        $currentV4 +
        $currentV6


    if ($currentTotal -gt 0) {

        $v4CurrentPct = [math]::Round(
            ($currentV4 / $currentTotal) * 100
        )

        $v6CurrentPct =
            100 - $v4CurrentPct
    }
    else {

        $v4CurrentPct = 0
        $v6CurrentPct = 0
    }


    # -----------------------------------------------------------------------
    # Session split.
    # -----------------------------------------------------------------------

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

        $v4SessionPct = [math]::Round(
            ($sessionV4 / $sessionTotal) * 100
        )

        $v6SessionPct =
            100 - $v4SessionPct
    }
    else {

        $v4SessionPct = 0
        $v6SessionPct = 0
    }


    # -----------------------------------------------------------------------
    # Display.
    # -----------------------------------------------------------------------

    Clear-Host


    Write-Host "=== IPv4 vs IPv6 TRAFFIC MONITOR ===" `
        -ForegroundColor Yellow

    Write-Host "Interface: $interfaceName"
    Write-Host "TShark interface: $interfaceNumber"

    Write-Host "Capture mode: continuous" `
        -ForegroundColor DarkGray

    Write-Host (
        "Measurement window: {0:N2} sec" -f `
            $ActualWindowSeconds
    ) -ForegroundColor DarkGray


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


    Write-Host (
        "Controls: [P] Pause display   [Q] Quit`n"
    ) -ForegroundColor DarkGray


    # -----------------------------------------------------------------------
    # Real-time.
    # -----------------------------------------------------------------------

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


    # -----------------------------------------------------------------------
    # Session.
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
                $v4SessionPct,
                $v6SessionPct
        ) -ForegroundColor Yellow
    }
    else {

        Write-Host "Overall Split: [No Data Yet]" `
            -ForegroundColor DarkGray
    }
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


# -l tells TShark to flush packet output continuously.

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
    "-e", "ipv6.dst"
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


# ---------------------------------------------------------------------------
# Drain stderr asynchronously.
#
# This prevents TShark from ever blocking because its stderr pipe filled.
# ---------------------------------------------------------------------------

$stderrTask =
    $process.StandardError.ReadToEndAsync()


# ---------------------------------------------------------------------------
# Timing.
# ---------------------------------------------------------------------------

$windowStartedAt =
    [DateTimeOffset]::UtcNow

$nextWindowAt =
    $windowStartedAt.AddSeconds(
        $windowSeconds
    )

$readTask = $null

$unexpectedExit = $false
$exitCode = $null
$stderrText = ""


try {

    :monitor while ($true) {

        # -------------------------------------------------------------------
        # Keyboard.
        #
        # Capture continues regardless of pause state.
        # -------------------------------------------------------------------

        while ([Console]::KeyAvailable) {

            $key =
                [Console]::ReadKey($true)

            switch ($key.Key) {

                'P' {

                    $paused = -not $paused

                    if ($paused) {

                        Write-Host ""
                        Write-Host (
                            "=== PAUSED - capture continues. Press P to resume ==="
                        ) -ForegroundColor Yellow
                    }
                }


                'Q' {
                    break monitor
                }
            }
        }


        # -------------------------------------------------------------------
        # Check TShark.
        # -------------------------------------------------------------------

        if ($process.HasExited) {

            $unexpectedExit = $true
            $exitCode = $process.ExitCode

            break
        }


        # -------------------------------------------------------------------
        # Maintain one asynchronous stdout read.
        # -------------------------------------------------------------------

        if ($null -eq $readTask) {

            $readTask =
                $process.StandardOutput.ReadLineAsync()
        }


        # -------------------------------------------------------------------
        # Don't block longer than 50ms.
        #
        # This lets us:
        #
        #   - react quickly to P/Q
        #   - roll the one-second measurement window on time
        #   - still consume packets continuously
        # -------------------------------------------------------------------

        $now =
            [DateTimeOffset]::UtcNow

        $millisecondsUntilWindow =
            ($nextWindowAt - $now).TotalMilliseconds

        $waitMilliseconds =
            [int][math]::Max(
                1,
                [math]::Min(
                    50,
                    $millisecondsUntilWindow
                )
            )


        if ($readTask.Wait($waitMilliseconds)) {

            $line =
                $readTask.Result

            $readTask = $null


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
                -Window $window
        }


        # -------------------------------------------------------------------
        # Roll measurement window.
        #
        # IMPORTANT:
        #
        # TShark does NOT stop here.
        #
        # This only snapshots/resets PowerShell counters.
        # -------------------------------------------------------------------

        $now =
            [DateTimeOffset]::UtcNow


        if ($now -ge $nextWindowAt) {

            $actualWindowSeconds =
                ($now - $windowStartedAt).TotalSeconds

            if ($actualWindowSeconds -le 0) {
                $actualWindowSeconds = $windowSeconds
            }


            if (-not $paused) {

                Show-Dashboard `
                    -Session $session `
                    -Window $window `
                    -ActualWindowSeconds $actualWindowSeconds
            }


            # Reset ONLY the real-time window.
            #
            # Session totals continue forever until the script exits.

            $window = @{
                V4In  = [long]0
                V4Out = [long]0
                V6In  = [long]0
                V6Out = [long]0
            }


            $windowStartedAt =
                [DateTimeOffset]::UtcNow

            $nextWindowAt =
                $windowStartedAt.AddSeconds(
                    $windowSeconds
                )
        }
    }
}
finally {

    # -----------------------------------------------------------------------
    # Clean shutdown.
    # -----------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Unexpected TShark exit diagnostics.
# ---------------------------------------------------------------------------

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