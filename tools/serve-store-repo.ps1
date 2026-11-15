# Serve the shuios remote package repo over plain HTTP (no Python required).
#
#   powershell -ExecutionPolicy Bypass -File tools\serve-store-repo.ps1
#   powershell -ExecutionPolicy Bypass -File tools\serve-store-repo.ps1 -Port 8099
#
# Then point the guest at it (the data-partition override survives reboots):
#   echo 'repo = http://<host-ip>:8099' > /var/lib/shuios/pkg/repo.conf
# and click "刷新" in the store.
param(
    [int]$Port = 8099,
    [string]$Root = (Join-Path (Split-Path -Parent $PSScriptRoot) 'store-repo')
)

$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
$listener.Start()
Write-Host "shuios repo: $Root"
Write-Host "listening on http://0.0.0.0:$Port (Ctrl+C to stop)"
if (-not (Get-NetFirewallRule -DisplayName 'shuios-store-repo' -ErrorAction SilentlyContinue)) {
    Write-Host "tip: if the guest cannot connect, allow TCP $Port in Windows Firewall."
}

$types = @{
    '.json' = 'application/json'
    '.sqfs' = 'application/octet-stream'
    '.png'  = 'image/png'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
}

while ($true) {
    $client = $listener.AcceptTcpClient()
    $stream = $null
    try {
        $client.ReceiveTimeout = 15000
        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 4096, $true)
        $request = $reader.ReadLine()
        while ($true) {
            $h = $reader.ReadLine()
            if ([string]::IsNullOrEmpty($h)) { break }
        }
        if ($request -match '^(GET|HEAD)\s+(\S+)') {
            $method = $Matches[1]
            $path = [System.Uri]::UnescapeDataString($Matches[2].Split('?')[0])
            if ($path -eq '/') { $path = '/index.json' }
            $full = [System.IO.Path]::GetFullPath((Join-Path $Root ($path.TrimStart('/') -replace '/', '\')))
            $inside = $full.StartsWith($Root + '\', [System.StringComparison]::OrdinalIgnoreCase)
            if ($inside -and (Test-Path -LiteralPath $full -PathType Leaf)) {
                $info = Get-Item -LiteralPath $full
                $ct = $types[[System.IO.Path]::GetExtension($full).ToLower()]
                if (-not $ct) { $ct = 'application/octet-stream' }
                $head = "HTTP/1.1 200 OK`r`nContent-Type: $ct`r`nContent-Length: $($info.Length)`r`nConnection: close`r`n`r`n"
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($bytes, 0, $bytes.Length)
                if ($method -eq 'GET') {
                    $fs = [System.IO.File]::OpenRead($full)
                    try { $fs.CopyTo($stream, 1048576) } finally { $fs.Dispose() }
                }
                Write-Host "200 $method $path ($($info.Length) bytes)"
            } else {
                $body = [System.Text.Encoding]::ASCII.GetBytes("not found: $path")
                $head = "HTTP/1.1 404 Not Found`r`nContent-Type: text/plain`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Write($body, 0, $body.Length)
                Write-Host "404 $method $path"
            }
        }
    } catch {
        # One broken connection must not kill the server.
    } finally {
        if ($stream) { $stream.Dispose() }
        $client.Close()
    }
}
