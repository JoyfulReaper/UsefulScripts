param(
    [string[]]$AppLogPaths = @(
        ".\logs\*.log",
        ".\logs\stdout*.log"
    ),

    [string[]]$IisLogPaths = @(
        "C:\inetpub\logs\LogFiles\W3SVC*\*.log"
    ),

    [string[]]$AppPatterns = @(
        "Exception",
        "Unhandled",
        "fail",
        "failed",
        "error",
        "critical",
        "StackTrace",
        "NullReferenceException",
        "InvalidOperationException",
        "ArgumentException"
    ),

    [int[]]$IisStatusCodes = @(400, 401, 403, 404, 410, 429, 500, 502, 503),

    [int]$Last = 100,

    [switch]$NewestFilesOnly,

    [int]$NewestFileCount = 10
)

$ErrorActionPreference = "Stop"

function Get-LogFiles {
    param([string[]]$Paths)

    $files = foreach ($path in $Paths) {
        Get-ChildItem -Path $path -File -ErrorAction SilentlyContinue
    }

    $files |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Unique
}

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host "================================================================================" -ForegroundColor DarkGray
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor DarkGray
}

function Get-StatusColor {
    param([int]$Status)

    if ($Status -ge 500) { return "Red" }
    if ($Status -eq 404) { return "Yellow" }
    if ($Status -ge 400) { return "Magenta" }
    return "Gray"
}

function Parse-IisW3cLine {
    param(
        [string]$Line,
        [string[]]$Fields
    )

    if ([string]::IsNullOrWhiteSpace($Line) -or $Line.StartsWith("#")) {
        return $null
    }

    $values = $Line -split "\s+"

    if ($values.Count -lt $Fields.Count) {
        return $null
    }

    $row = @{}

    for ($i = 0; $i -lt $Fields.Count; $i++) {
        $row[$Fields[$i]] = $values[$i]
    }

    return $row
}

function Format-UserAgent {
    param([string]$UserAgent)

    if ([string]::IsNullOrWhiteSpace($UserAgent) -or $UserAgent -eq "-") {
        return "-"
    }

    return [uri]::UnescapeDataString($UserAgent.Replace("+", " "))
}

$appFiles = Get-LogFiles -Paths $AppLogPaths
$iisFiles = Get-LogFiles -Paths $IisLogPaths

if ($NewestFilesOnly) {
    $appFiles = $appFiles | Select-Object -First $NewestFileCount
    $iisFiles = $iisFiles | Select-Object -First $NewestFileCount
}

Write-Host "App log files: $($appFiles.Count)" -ForegroundColor DarkGray
Write-Host "IIS log files: $($iisFiles.Count)" -ForegroundColor DarkGray
Write-Host "Showing newest $Last result(s)." -ForegroundColor DarkGray

# -------------------------
# App/stdout log search
# -------------------------

Write-Section "APP / STDOUT LOG MATCHES"

$appMatches = @()

if ($appFiles) {
    $appRegex = ($AppPatterns | ForEach-Object { [regex]::Escape($_) }) -join "|"

    $appMatches = foreach ($file in $appFiles) {
        Select-String `
            -Path $file.FullName `
            -Pattern $appRegex `
            -CaseSensitive:$false `
            -ErrorAction SilentlyContinue |
            ForEach-Object {
                [pscustomobject]@{
                    LastWriteTime = $file.LastWriteTime
                    File          = $file.FullName
                    LineNumber    = $_.LineNumber
                    Line          = $_.Line.Trim()
                }
            }
    }

    $appMatches = $appMatches |
        Sort-Object LastWriteTime, File, LineNumber -Descending |
        Select-Object -First $Last
}

if (-not $appMatches) {
    Write-Host "No app/stdout matches found." -ForegroundColor Green
}
else {
    foreach ($match in $appMatches) {
        Write-Host ""
        Write-Host "APP MATCH" -ForegroundColor Red -NoNewline
        Write-Host "  $($match.File):$($match.LineNumber)" -ForegroundColor DarkGray
        Write-Host "  Updated: $($match.LastWriteTime)" -ForegroundColor DarkGray
        Write-Host "  $($match.Line)" -ForegroundColor White
    }
}

# -------------------------
# IIS W3C parsed search
# -------------------------

Write-Section "IIS ERROR MATCHES"

$iisMatches = @()

foreach ($file in $iisFiles) {
    $fields = $null
    $lineNumber = 0

    foreach ($line in Get-Content -Path $file.FullName -ErrorAction SilentlyContinue) {
        $lineNumber++

        if ($line.StartsWith("#Fields:")) {
            $fields = $line.Substring("#Fields:".Length).Trim() -split "\s+"
            continue
        }

        if (-not $fields) {
            continue
        }

        $row = Parse-IisW3cLine -Line $line -Fields $fields

        if (-not $row) {
            continue
        }

        $statusRaw = $row["sc-status"]

        if (-not $statusRaw) {
            continue
        }

        $status = 0
        if (-not [int]::TryParse($statusRaw, [ref]$status)) {
            continue
        }

        if ($IisStatusCodes -notcontains $status) {
            continue
        }

        $uriStem = $row["cs-uri-stem"]
        $uriQuery = $row["cs-uri-query"]
        $method = $row["cs-method"]
        $subStatus = $row["sc-substatus"]
        $win32Status = $row["sc-win32-status"]
        $timeTaken = $row["time-taken"]
        $referer = $row["cs(Referer)"]
        $userAgent = Format-UserAgent $row["cs(User-Agent)"]

        $url = $uriStem
        if ($uriQuery -and $uriQuery -ne "-") {
            $url = "$uriStem`?$uriQuery"
        }

        $iisMatches += [pscustomobject]@{
            File          = $file.FullName
            LastWriteTime = $file.LastWriteTime
            LineNumber    = $lineNumber
            Date          = $row["date"]
            Time          = $row["time"]
            Method        = $method
            Url           = $url
            Status        = $status
            SubStatus     = $subStatus
            Win32Status   = $win32Status
            TimeTakenMs   = $timeTaken
            Referer       = $referer
            UserAgent     = $userAgent
        }
    }
}

$iisMatches = $iisMatches |
    Sort-Object Date, Time -Descending |
    Select-Object -First $Last

if (-not $iisMatches) {
    Write-Host "No IIS error status matches found." -ForegroundColor Green
}
else {
    foreach ($match in $iisMatches) {
        $statusColor = Get-StatusColor -Status $match.Status

        Write-Host ""
        Write-Host "HTTP " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($match.Status)" -NoNewline -ForegroundColor $statusColor
        Write-Host "  $($match.Method) $($match.Url)" -ForegroundColor White

        Write-Host "  Time:       $($match.Date) $($match.Time) UTC" -ForegroundColor DarkGray
        Write-Host "  IIS:        $($match.Status).$($match.SubStatus)  Win32=$($match.Win32Status)  Took=$($match.TimeTakenMs)ms" -ForegroundColor DarkGray
        Write-Host "  File:       $($match.File):$($match.LineNumber)" -ForegroundColor DarkGray

        if ($match.Referer -and $match.Referer -ne "-") {
            Write-Host "  Referer:    $($match.Referer)" -ForegroundColor DarkGray
        }

        if ($match.UserAgent -and $match.UserAgent -ne "-") {
            Write-Host "  Agent:      $($match.UserAgent)" -ForegroundColor DarkGray
        }
    }
}

# -------------------------
# Summary
# -------------------------

Write-Section "SUMMARY"

if ($iisMatches) {
    $iisMatches |
        Group-Object Status |
        Sort-Object Name |
        ForEach-Object {
            $color = Get-StatusColor -Status ([int]$_.Name)
            Write-Host "HTTP " -NoNewline -ForegroundColor DarkGray
            Write-Host $_.Name -NoNewline -ForegroundColor $color
            Write-Host ": $($_.Count)"
        }

    Write-Host ""

    $iisMatches |
        Group-Object Url |
        Sort-Object Count -Descending |
        Select-Object -First 10 |
        ForEach-Object {
            Write-Host "$($_.Count)x  $($_.Name)" -ForegroundColor DarkGray
        }
}
else {
    Write-Host "No IIS errors to summarize." -ForegroundColor Green
}