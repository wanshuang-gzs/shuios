# Real drag test through QMP: the usb-tablet is an absolute device, so HMP's
# mouse_move does nothing; input-send-event with an "abs" axis does.
# Pure ASCII.
param(
    [int]$FromX = 640,
    [int]$FromY = 120,
    [int]$ToX = 200,
    [int]$ToY = 420,
    [int]$Steps = 6
)

$MAX = 0x7FFF

function Qmp {
    param([string]$Json)
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 5556)
    $s = $c.GetStream()
    $r = New-Object System.IO.StreamReader($s)
    $w = New-Object System.IO.StreamWriter($s)
    $w.NewLine = "`n"
    # greeting
    $null = $r.ReadLine()
    $w.WriteLine('{"execute":"qmp_capabilities"}'); $w.Flush()
    Start-Sleep -Milliseconds 80
    $w.WriteLine($Json); $w.Flush()
    Start-Sleep -Milliseconds 120
    $c.Close()
}

function AbsMove {
    param([int]$X, [int]$Y)
    $ax = [int]([double]$X / 1280.0 * $MAX)
    $ay = [int]([double]$Y / 800.0 * $MAX)
    $j = '{"execute":"input-send-event","arguments":{"events":[' +
         '{"type":"abs","data":{"axis":"x","value":' + $ax + '}},' +
         '{"type":"abs","data":{"axis":"y","value":' + $ay + '}}]}}'
    Qmp $j
}

function Button {
    param([bool]$Down)
    $j = '{"execute":"input-send-event","arguments":{"events":[' +
         '{"type":"btn","data":{"down":' + $Down.ToString().ToLower() + ',"button":"left"}}]}}'
    Qmp $j
}

Write-Host "drag $FromX,$FromY -> $ToX,$ToY"
AbsMove $FromX $FromY
Start-Sleep -Milliseconds 400
Button $true
Start-Sleep -Milliseconds 400
for ($i = 1; $i -le $Steps; $i++) {
    $x = [int]($FromX + ($ToX - $FromX) * $i / $Steps)
    $y = [int]($FromY + ($ToY - $FromY) * $i / $Steps)
    AbsMove $x $y
}
Start-Sleep -Milliseconds 300
Button $false
Start-Sleep -Milliseconds 900

powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\shuios\tools\vm-shot.ps1' -Out 'D:\shuios\.cache\qmp-drag.ppm' | Out-Null
Write-Host "captured"
