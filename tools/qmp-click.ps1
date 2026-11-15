# QMP helper: click at absolute guest coordinates (pure ASCII).
param(
    [int]$X = 234,
    [int]$Y = 672
)

$MAX = 0x7FFF

function Send-Qmp {
    param([string[]]$Lines)
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 5556)
    try {
        $s = $c.GetStream()
        $r = New-Object System.IO.StreamReader($s)
        $w = New-Object System.IO.StreamWriter($s)
        $w.NewLine = "`n"
        $null = $r.ReadLine()
        foreach ($line in $Lines) {
            $w.WriteLine($line)
            $w.Flush()
            Start-Sleep -Milliseconds 120
            if ($r.Peek() -ge 0) { $null = $r.ReadLine() }
        }
    } finally {
        $c.Close()
    }
}

# connectivity check
Send-Qmp @('{"execute":"qmp_capabilities"}', '{"execute":"query-status"}')
Write-Host "qmp ok"

$ax = [int]([double]$X / 1280.0 * $MAX)
$ay = [int]([double]$Y / 800.0 * $MAX)

$move = '{"execute":"input-send-event","arguments":{"events":[' +
        '{"type":"abs","data":{"axis":"x","value":' + $ax + '}},' +
        '{"type":"abs","data":{"axis":"y","value":' + $ay + '}}]}}'
Send-Qmp @($move)
Start-Sleep -Milliseconds 400
Send-Qmp @('{"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"down":true,"button":"left"}}]}}')
Start-Sleep -Milliseconds 150
Send-Qmp @('{"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"down":false,"button":"left"}}]}}')
Start-Sleep -Milliseconds 500

powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\shuios\tools\vm-shot.ps1' -Out 'D:\shuios\.cache\click.ppm' | Out-Null
Write-Host "clicked at $X,$Y"
