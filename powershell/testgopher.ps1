param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^gophers?://')]
    [string]$Url
)

$curl = Get-Command curl.exe -ErrorAction SilentlyContinue

if (-not $curl) {
    Write-Error "curl.exe was not found in PATH."
    exit 1
}

$writeOut = '{"remoteIp":"%{remote_ip}","remotePort":%{remote_port},"dns":%{time_namelookup},"connect":%{time_connect},"total":%{time_total},"size":%{size_download},"speed":%{speed_download}}'

$json = curl.exe `
    --silent `
    --show-error `
    --output NUL `
    --write-out $writeOut `
    $Url

if ($LASTEXITCODE -ne 0) {
    Write-Error "curl failed with exit code $LASTEXITCODE."
    exit $LASTEXITCODE
}

try {
    $result = $json | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Error "Could not parse curl output as JSON: $json"
    exit 1
}

$dnsMilliseconds          = $result.dns * 1000
$tcpHandshakeMilliseconds = ($result.connect - $result.dns) * 1000
$postConnectMilliseconds  = ($result.total - $result.connect) * 1000
$totalMilliseconds        = $result.total * 1000

$addressFamily = if ($result.remoteIp -like '*:*') {
    'IPv6'
}
else {
    'IPv4'
}

@"
URL:                  $Url
Remote endpoint:      [$($result.remoteIp)]:$($result.remotePort)
Address family:       $addressFamily
DNS lookup:           $("{0:N3}" -f $dnsMilliseconds) ms
TCP handshake:        $("{0:N3}" -f $tcpHandshakeMilliseconds) ms
Post-connect transfer:$("{0,10:N3}" -f $postConnectMilliseconds) ms
Total:                $("{0:N3}" -f $totalMilliseconds) ms
Size:                 $($result.size) bytes
Average speed:        $("{0:N0}" -f $result.speed) bytes/sec
"@