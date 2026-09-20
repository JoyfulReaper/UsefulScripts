$xsrf = ''
$session = ''

$cookie = "test; bhr4HasEnteredAdvanced=false; Session=$session; XSRF-TOKEN=$xsrf"

$ports = @{
    23    = 10023
    80    = 10080
    443   = 10443
    445   = 10445
    420   = 10420
    2323  = 12323
    3389  = 13389
    5432  = 15432
    6379  = 16379
    8080  = 18080
    9200  = 19200
    42069 = 52069
}

foreach ($p in $ports.Keys) {
    $forwardPort = $ports[$p]
    $name = "PortForward_$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"

    $body = @{
        enabled  = $true
        deviceIp = "192.168.1.2"
        name     = $name
        protocols = @(
            @{
                protocol          = 1
                incomingPorts     = 0
                incomingPortStart = 0
                incomingPortEnd   = 65535
                incomingExclude   = $false
                outgoingPorts     = 1
                outgoingPortStart = $p
                outgoingPortEnd   = $p
                outgoingExclude   = $false
            }
        )
        schedule    = "Always"
        servicePort = $forwardPort
    } | ConvertTo-Json -Depth 5 -Compress

    Write-Host "$p -> $forwardPort"

    curl.exe `
        --silent `
        --show-error `
        --insecure `
        --url "https://192.168.1.1/api/firewall/portforward" `
        -H "Content-Type: application/json;charset=UTF-8" `
        -H "X-XSRF-TOKEN: $xsrf" `
        -H "Origin: https://192.168.1.1" `
        -H "Referer: https://192.168.1.1/" `
        -b $cookie `
        --data-raw $body

    Start-Sleep -Milliseconds 100
}