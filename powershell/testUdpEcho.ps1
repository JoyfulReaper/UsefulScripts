param(
    [string]$HostName = "127.0.0.1",
    [int]$Port = 7007,
    [string]$Message = "hello udp echo"
)

$client = [System.Net.Sockets.UdpClient]::new()
$client.Client.ReceiveTimeout = 2000

try {
    $address = [System.Net.Dns]::GetHostAddresses($HostName) |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        Select-Object -First 1

    if ($null -eq $address) {
        throw "No IPv4 address found for $HostName"
    }

    $endpoint = [System.Net.IPEndPoint]::new($address, $Port)
    $payload = [System.Text.Encoding]::UTF8.GetBytes($Message)

    [void]$client.Send($payload, $payload.Length, $endpoint)

    $remote = [System.Net.IPEndPoint]::new(
        [System.Net.IPAddress]::Any,
        0
    )

    $response = $client.Receive([ref]$remote)
    $text = [System.Text.Encoding]::UTF8.GetString($response)

    if ($text -ne $Message) {
        throw "Echo mismatch. Sent '$Message', got '$text'"
    }

    "OK: received '$text' from $remote"
}
finally {
    $client.Dispose()
}