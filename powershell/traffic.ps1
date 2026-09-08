$ErrorActionPreference = 'SilentlyContinue'

# Grab active connected network adapter
$adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1

if (-not $adapter) {
    Write-Host "No active network adapter found!" -ForegroundColor Red
    return
}

# Initialize session counters for accumulation
$totalV4InBytes  = 0
$totalV4OutBytes = 0
$totalV6InBytes  = 0
$totalV6OutBytes = 0

Write-Host "Monitoring IPv4 vs IPv6 on: $($adapter.Name)" -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop.`n"

while ($true) {
    # Sample 1: Get raw datagram counters via CIM/WMI
    $v4Before = Get-CimInstance -ClassName Win32_PerfRawData_TCPIP_IPv4
    $v6Before = Get-CimInstance -ClassName Win32_PerfRawData_TCPIP_IPv6
    $timeBefore = Get-Date

    Start-Sleep -Seconds 1

    # Sample 2: Get second snapshot
    $v4After = Get-CimInstance -ClassName Win32_PerfRawData_TCPIP_IPv4
    $v6After = Get-CimInstance -ClassName Win32_PerfRawData_TCPIP_IPv6
    $timeAfter = Get-Date

    $elapsed = ($timeAfter - $timeBefore).TotalSeconds

    # Calculate raw datagram deltas
    $v4InDg  = $v4After.DatagramsReceivedPersec - $v4Before.DatagramsReceivedPersec
    $v4OutDg = $v4After.DatagramsSentPersec - $v4Before.DatagramsSentPersec
    $v6InDg  = $v6After.DatagramsReceivedPersec - $v6Before.DatagramsReceivedPersec
    $v6OutDg = $v6After.DatagramsSentPersec - $v6Before.DatagramsSentPersec

    # Prevent negative values on counter resets
    if ($v4InDg -lt 0)  { $v4InDg = 0 }
    if ($v4OutDg -lt 0) { $v4OutDg = 0 }
    if ($v6InDg -lt 0)  { $v6InDg = 0 }
    if ($v6OutDg -lt 0) { $v6OutDg = 0 }

    # Estimate bytes transferred in this 1-second sample (~1460 bytes per datagram)
    $v4InSampleBytes  = $v4InDg * 1460
    $v4OutSampleBytes = $v4OutDg * 1460
    $v6InSampleBytes  = $v6InDg * 1460
    $v6OutSampleBytes = $v6OutDg * 1460

    # Accumulate totals across script lifetime
    $totalV4InBytes  += $v4InSampleBytes
    $totalV4OutBytes += $v4OutSampleBytes
    $totalV6InBytes  += $v6InSampleBytes
    $totalV6OutBytes += $v6OutSampleBytes

    # Real-time speeds in KB/s
    $v4InSpeed  = [math]::Round(($v4InSampleBytes / 1KB) / $elapsed, 1)
    $v4OutSpeed = [math]::Round(($v4OutSampleBytes / 1KB) / $elapsed, 1)
    $v6InSpeed  = [math]::Round(($v6InSampleBytes / 1KB) / $elapsed, 1)
    $v6OutSpeed = [math]::Round(($v6OutSampleBytes / 1KB) / $elapsed, 1)

    # Convert totals to MB
    $v4InMB  = [math]::Round($totalV4InBytes / 1MB, 2)
    $v4OutMB = [math]::Round($totalV4OutBytes / 1MB, 2)
    $v6InMB  = [math]::Round($totalV6InBytes / 1MB, 2)
    $v6OutMB = [math]::Round($totalV6OutBytes / 1MB, 2)

    # Display Readout
    Clear-Host
    Write-Host "=== REAL-TIME & ACCUMULATED TRAFFIC MONITOR ===" -ForegroundColor Yellow
    Write-Host "Interface: $($adapter.Name) ($($adapter.InterfaceDescription))`n"

    Write-Host "--- REAL-TIME SPEEDS ---" -ForegroundColor Cyan
    Write-Host ("IPv4 Download: {0,8} KB/s  |  IPv4 Upload: {1,8} KB/s" -f $v4InSpeed, $v4OutSpeed) -ForegroundColor Green
    Write-Host ("IPv6 Download: {0,8} KB/s  |  IPv6 Upload: {1,8} KB/s" -f $v6InSpeed, $v6OutSpeed) -ForegroundColor Magenta

    $realtimeTotalIn = $v4InSpeed + $v6InSpeed
    if ($realtimeTotalIn -gt 0) {
        $v4SpeedPct = [math]::Round(($v4InSpeed / $realtimeTotalIn) * 100)
        $v6SpeedPct = 100 - $v4SpeedPct
        Write-Host ("Real-Time Split: IPv4 [{0}%]  vs  IPv6 [{1}%]" -f $v4SpeedPct, $v6SpeedPct) -ForegroundColor DarkGray
    } else {
        Write-Host "Real-Time Split: [Idle]" -ForegroundColor DarkGray
    }

    Write-Host "`n--- TOTAL ACCUMULATED TRANSFERS (THIS SESSION) ---" -ForegroundColor Cyan
    Write-Host ("IPv4 Download: {0,8} MB    |  IPv4 Upload: {1,8} MB" -f $v4InMB, $v4OutMB) -ForegroundColor Green
    Write-Host ("IPv6 Download: {0,8} MB    |  IPv6 Upload: {1,8} MB" -f $v6InMB, $v6OutMB) -ForegroundColor Magenta

    $totalSessionIn = $totalV4InBytes + $totalV6InBytes
    if ($totalSessionIn -gt 0) {
        $v4TotalPct = [math]::Round(($totalV4InBytes / $totalSessionIn) * 100)
        $v6TotalPct = 100 - $v4TotalPct
        Write-Host ("Overall Split:   IPv4 [{0}%]  vs  IPv6 [{1}%]" -f $v4TotalPct, $v6TotalPct) -ForegroundColor Yellow
    } else {
        Write-Host "Overall Split:   [No Data Yet]" -ForegroundColor DarkGray
    }
}