$ApiUrl = "https://cp.green.cloud/api/server/b1accaf4-4263-4ec5-ae3b-d29cc880d98d?state=true"
$PollSeconds = 300

# Prefer an environment variable:
#   $env:GREEN_CLOUD_TOKEN = "your-token"
#
# If it isn't set, securely prompt for the token.
$Token = $env:GREEN_CLOUD_TOKEN

if (-not $Token) {
    $SecureToken = Read-Host "GreenCloud Bearer Token" -AsSecureString

    $Ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)
    try {
        $Token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Ptr)
    }
}

$Headers = @{
    Authorization = "Bearer $Token"
    Accept        = "application/json"
}

function Convert-LimitToBytes {
    param([string]$Limit)

    if ($Limit -notmatch '([\d.]+)\s*(KB|MB|GB|TB)') {
        throw "Unknown bandwidth limit format: $Limit"
    }

    $Amount = [double]$Matches[1]
    $Unit   = $Matches[2].ToUpper()

    switch ($Unit) {
        "KB" { return $Amount * 1KB }
        "MB" { return $Amount * 1MB }
        "GB" { return $Amount * 1GB }
        "TB" { return $Amount * 1TB }
    }
}

function Format-GB {
    param([double]$Bytes)

    return "{0:N2} GB" -f ($Bytes / 1GB)
}

function Format-Rate {
    param([double]$BytesPerSecond)

    $Mbps = ($BytesPerSecond * 8) / 1MB

    if ($Mbps -ge 1) {
        return "{0:N2} Mbps" -f $Mbps
    }

    $Kbps = ($BytesPerSecond * 8) / 1KB
    return "{0:N2} Kbps" -f $Kbps
}

$PreviousRx = $null
$PreviousTx = $null
$PreviousTime = $null

while ($true) {
    try {
        $Response = Invoke-RestMethod `
            -Uri $ApiUrl `
            -Headers $Headers `
            -Method Get `
            -TimeoutSec 15

        $Server = $Response.data

        $Traffic = $Server.state.network.primary.traffic

        [double]$Rx    = $Traffic.rx
        [double]$Tx    = $Traffic.tx
        [double]$Used  = $Traffic.total

        $LimitText = $Server.network.primary.limit
        [double]$Limit = Convert-LimitToBytes $LimitText

        [double]$Remaining = [Math]::Max($Limit - $Used, 0)

        $UsedPercent = ($Used / $Limit) * 100
        $RemainingPercent = ($Remaining / $Limit) * 100

        $PeriodStart = [DateTimeOffset]::Parse(
            $Server.currentMonthlyPeriod.start
        )

        $PeriodEnd = [DateTimeOffset]::Parse(
            $Server.currentMonthlyPeriod.end
        )

        $Now = [DateTimeOffset]::UtcNow

        $ElapsedDays = ($Now - $PeriodStart).TotalDays
        $DaysRemaining = ($PeriodEnd - $Now).TotalDays

        if ($ElapsedDays -lt 0.001) {
            $ElapsedDays = 0.001
        }

        if ($DaysRemaining -lt 0) {
            $DaysRemaining = 0
        }

        $AveragePerDay = $Used / $ElapsedDays

        if ($DaysRemaining -gt 0) {
            $SafePerDay = $Remaining / $DaysRemaining
            $ProjectedTotal = $Used + ($AveragePerDay * $DaysRemaining)
        }
        else {
            $SafePerDay = 0
            $ProjectedTotal = $Used
        }

        #
        # Calculate current RX/TX rate based on difference
        # between this poll and the previous poll.
        #
        $RxRate = $null
        $TxRate = $null

        if ($null -ne $PreviousTime) {
            $Seconds = ($Now - $PreviousTime).TotalSeconds

            if ($Seconds -gt 0) {
                $RxDifference = $Rx - $PreviousRx
                $TxDifference = $Tx - $PreviousTx

                if ($RxDifference -ge 0) {
                    $RxRate = $RxDifference / $Seconds
                }

                if ($TxDifference -ge 0) {
                    $TxRate = $TxDifference / $Seconds
                }
            }
        }

        $PreviousRx = $Rx
        $PreviousTx = $Tx
        $PreviousTime = $Now

        Clear-Host

        Write-Host "GREEN CLOUD SERVER MONITOR"
        Write-Host ("=" * 64)

        Write-Host ("Server:           {0}" -f $Server.name)
        Write-Host ("Status:           {0}" -f $Server.state.status)
        Write-Host ("CPU Usage:        {0}" -f $Server.state.cpu)
        Write-Host ("CPU:              {0}" -f $Server.cpu)
        Write-Host ("Memory:           {0}" -f $Server.memory)

        if ($Server.network.primary.ipv4.Count -gt 0) {
            Write-Host (
                "IPv4:             {0}" -f
                $Server.network.primary.ipv4[0].address
            )
        }

        Write-Host ""
        Write-Host "BANDWIDTH"
        Write-Host ("-" * 64)

        Write-Host ("Monthly limit:    {0}" -f $LimitText)
        Write-Host ("RX / Downloaded:  {0}" -f (Format-GB $Rx))
        Write-Host ("TX / Uploaded:    {0}" -f (Format-GB $Tx))

        Write-Host (
            "Total used:       {0} ({1:N2}%)" -f
            (Format-GB $Used),
            $UsedPercent
        )

        Write-Host (
            "Remaining:        {0} ({1:N2}%)" -f
            (Format-GB $Remaining),
            $RemainingPercent
        )

        Write-Host ""
        Write-Host "CURRENT TRAFFIC"
        Write-Host ("-" * 64)

        if ($null -ne $RxRate) {
            Write-Host ("RX rate:          {0}" -f (Format-Rate $RxRate))
            Write-Host ("TX rate:          {0}" -f (Format-Rate $TxRate))
        }
        else {
            Write-Host "RX rate:          Calculating..."
            Write-Host "TX rate:          Calculating..."
        }

        Write-Host ""
        Write-Host "BILLING PERIOD"
        Write-Host ("-" * 64)

        Write-Host (
            "Start:            {0}" -f
            $PeriodStart.ToString("yyyy-MM-dd HH:mm 'UTC'")
        )

        Write-Host (
            "End:              {0}" -f
            $PeriodEnd.ToString("yyyy-MM-dd HH:mm 'UTC'")
        )

        Write-Host ("Days elapsed:     {0:N2}" -f $ElapsedDays)
        Write-Host ("Days remaining:   {0:N2}" -f $DaysRemaining)

        Write-Host ""
        Write-Host "USAGE / PROJECTION"
        Write-Host ("-" * 64)

        Write-Host (
            "Average usage:    {0}/day" -f
            (Format-GB $AveragePerDay)
        )

        if ($DaysRemaining -gt 0) {
            Write-Host (
                "Available/day:    {0}/day" -f
                (Format-GB $SafePerDay)
            )

            Write-Host (
                "Projected total:  {0}" -f
                (Format-GB $ProjectedTotal)
            )

            if ($ProjectedTotal -le $Limit) {
                $ProjectedPercentage = (
                    $ProjectedTotal / $Limit
                ) * 100

                Write-Host (
                    "Projection:       OK - {0:N1}% of monthly allowance" -f
                    $ProjectedPercentage
                )
            }
            else {
                $Overage = $ProjectedTotal - $Limit

                Write-Host (
                    "Projection:       OVER LIMIT by approximately {0}" -f
                    (Format-GB $Overage)
                )
            }
        }

        Write-Host ""
        Write-Host ("=" * 64)

        Write-Host (
            "Updated: {0} | Refresh: {1}s | Ctrl+C to exit" -f
            $Now.ToString("yyyy-MM-dd HH:mm:ss 'UTC'"),
            $PollSeconds
        )
    }
    catch {
        Clear-Host
        Write-Host "GreenCloud API request failed."
        Write-Host ""
        Write-Host $_.Exception.Message
        Write-Host ""
        Write-Host "Retrying in $PollSeconds seconds..."
    }

    Start-Sleep -Seconds $PollSeconds
}