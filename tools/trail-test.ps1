# Move the mouse via the QEMU monitor and capture frames to detect smearing.
# Pure ASCII (PowerShell 5.1 reads .ps1 as ANSI without BOM).
param(
    [int]$Steps = 5,
    [int]$Dx = 150,
    [int]$Dy = 100
)

function Send-Monitor {
    param([string]$Cmd)
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 5555)
    $s = $c.GetStream()
    $w = New-Object System.IO.StreamWriter($s)
    $w.NewLine = "`n"
    $w.WriteLine($Cmd)
    $w.Flush()
    Start-Sleep -Milliseconds 120
    $c.Close()
}

$qemuShot = 'D:\shuios\tools\vm-shot.ps1'
$before = 'D:\shuios\.cache\trail-before.ppm'
powershell -NoProfile -ExecutionPolicy Bypass -File $qemuShot -Out $before | Out-Null

for ($i = 1; $i -le $Steps; $i++) {
    Send-Monitor "mouse_move $Dx $Dy"
    Start-Sleep -Milliseconds 400
}
Start-Sleep -Milliseconds 600
$after = 'D:\shuios\.cache\trail-after.ppm'
powershell -NoProfile -ExecutionPolicy Bypass -File $qemuShot -Out $after | Out-Null

# Count differing pixels between the two frames with python.
py -3 -c @"
import sys
def load(p):
    d = open(p, 'rb').read()
    parts = d.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]
w1, h1, a = load(r'D:\shuios\.cache\trail-before.ppm')
w2, h2, b = load(r'D:\shuios\.cache\trail-after.ppm')
n = min(len(a), len(b))
diff = 0
xs = []
ys = []
for i in range(0, n, 3):
    if a[i:i+3] != b[i:i+3]:
        diff += 1
        p = i // 3
        xs.append(p % w1)
        ys.append(p // w1)
print('画面尺寸', w1, h1)
print('变化像素', diff)
if xs:
    print('变化范围 x', min(xs), '..', max(xs), ' y', min(ys), '..', max(ys))
"@
