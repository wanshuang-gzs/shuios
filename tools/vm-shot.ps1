# Take one or more QEMU screenshots over a single monitor connection.
#
# QEMU's HMP monitor accepts only one client at a time; opening a new TCP
# connection for every shot can wedge it (later connects get refused), so this
# script keeps one connection open and issues `screendump` repeatedly.
#
# Usage:
#   powershell -File tools\vm-shot.ps1 -Out D:\shuios\.cache\a.ppm
#   powershell -File tools\vm-shot.ps1 -Out D:\shuios\.cache\seq.ppm -Count 4 -Interval 800
param(
    [string]$MonitorHost = '127.0.0.1',
    [int]$MonitorPort = 5555,
    [string]$Out = 'D:\shuios\.cache\shot.ppm',
    [int]$Count = 1,
    [int]$Interval = 0
)

function Shot($stream, $outFile) {
    $path = $outFile -replace '\\', '/'
    if (Test-Path $outFile) { Remove-Item $outFile -Force }
    $cmd = "screendump $path`n"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($cmd)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 100
        if (Test-Path $outFile) {
            if ((Get-Item $outFile).Length -gt 1024) { return $true }
        }
    }
    return $false
}

try {
    $client = New-Object System.Net.Sockets.TcpClient
    $client.NoDelay = $true
    $client.Connect($MonitorHost, $MonitorPort)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 3000
    Start-Sleep -Milliseconds 300

    if ($stream.DataAvailable) {
        $buf = New-Object byte[] 8192
        [void]$stream.Read($buf, 0, $buf.Length)
    }

    for ($n = 1; $n -le $Count; $n++) {
        $target = if ($Count -eq 1) { $Out } else {
            [System.IO.Path]::Combine(
                [System.IO.Path]::GetDirectoryName($Out),
                [System.IO.Path]::GetFileNameWithoutExtension($Out) + "-$n" +
                [System.IO.Path]::GetExtension($Out))
        }
        if (Shot $stream $target) {
            Write-Host "screenshot: $target ($((Get-Item $target).Length) bytes)"
        } else {
            Write-Host "no screenshot produced for $target"
        }
        if ($n -lt $Count -and $Interval -gt 0) { Start-Sleep -Milliseconds $Interval }
    }

    $client.Client.Shutdown('Both')
    $stream.Close()
    $client.Close()
} catch {
    Write-Host "monitor error: $($_.Exception.Message)"
}
