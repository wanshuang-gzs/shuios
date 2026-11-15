# Try booting the VM with WHPX hardware acceleration (pure ASCII file).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\try-whpx.ps1 [-Cpu host|max] [-Seconds 45]
param(
    [string]$Cpu = 'host',
    [int]$Seconds = 45,
    [switch]$KeepRunning
)

$qemu = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$img = 'D:\shuios\shuios.img'
$ovmf = 'D:\shuios\.cache\ovmf'
$code = Join-Path $ovmf 'OVMF_CODE_4M.fd'
$vars = Join-Path $ovmf 'OVMF_VARS_whpx.fd'
Copy-Item (Join-Path $ovmf 'OVMF_VARS_4M.fd') $vars -Force
$serial = 'D:\shuios\.cache\whpx-serial.log'
Remove-Item $serial -ErrorAction SilentlyContinue

$args = @(
    '-machine', 'q35,accel=whpx',
    '-cpu', $Cpu,
    '-m', '4096',
    '-smp', '4',
    '-drive', "if=pflash,format=raw,readonly=on,file=$code",
    '-drive', "if=pflash,format=raw,file=$vars",
    '-drive', "file=$img,format=raw,if=ide,index=0",
    '-vga', 'std',
    '-display', 'none',
    '-chardev', "file,id=ser0,path=$serial",
    '-serial', 'chardev:ser0'
)

Write-Host "trying accel=whpx cpu=$Cpu"
$p = Start-Process -FilePath $qemu -ArgumentList $args -WorkingDirectory 'C:\Program Files\qemu' -PassThru -WindowStyle Hidden
Start-Sleep -Seconds $Seconds
$alive = -not $p.HasExited
Write-Host "qemu alive after ${Seconds}s: $alive  exit=$($p.ExitCode)"
if (Test-Path $serial) {
    Write-Host "--- serial tail ---"
    Get-Content $serial -Tail 25 -ErrorAction SilentlyContinue
} else {
    Write-Host "(no serial output)"
}
if (-not $KeepRunning) {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Write-Host "stopped"
}
