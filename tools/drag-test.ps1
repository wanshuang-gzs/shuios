# Drag a window with the injected mouse and check for ghost copies.
# Pure ASCII.
param(
    [int]$Moves = 3,
    [int]$Dx = 120,
    [int]$Dy = 90
)

function Send-Monitor {
    param([string]$Cmd)
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 5555)
    $s = $c.GetStream()
    $w = New-Object System.IO.StreamWriter($s)
    $w.NewLine = "`n"
    $w.WriteLine($Cmd)
    $w.Flush()
    Start-Sleep -Milliseconds 150
    $c.Close()
}

# Move onto the window header bar first (cursor is already inside the window).
Send-Monitor "mouse_move -40 -20"
Start-Sleep -Milliseconds 300
Send-Monitor "mouse_button 1"
Start-Sleep -Milliseconds 300
for ($i = 1; $i -le $Moves; $i++) {
    Send-Monitor "mouse_move $Dx $Dy"
    Start-Sleep -Milliseconds 500
}
Send-Monitor "mouse_button 0"
Start-Sleep -Milliseconds 800

powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\shuios\tools\vm-shot.ps1' -Out 'D:\shuios\.cache\drag-after.ppm' | Out-Null
Write-Host "dragged"
