# Try WHPX with the OVMF SMM configuration (pure ASCII).
# OVMF_CODE_4M.fd is the SMM-enabled build, so it must run with -machine q35,smm=on.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\try-whpx2.ps1 [-Mode smm|pc|smm-max]
param(
    [string]$Mode = 'smm',
    [int]$Seconds = 45
)

$qemu = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$img = 'D:\shuios\shuios.img'
$ovmf = 'D:\shuios\.cache\ovmf'
$code = Join-Path $ovmf 'OVMF_CODE_4M.fd'
$vars = 'D:\shuios\.cache\ovmf\OVMF_VARS_try.fd'
Copy-Item (Join-Path $ovmf 'OVMF_VARS_4M.fd') $vars -Force
$serial = 'D:\shuios\.cache\whpx2-serial.log'
Remove-Item $serial -ErrorAction SilentlyContinue

switch ($Mode) {
    'smm' {
        $machine = 'q35,accel=whpx,smm=on'
        $cpu = 'host'
    }
    'smm-max' {
        $machine = 'q35,accel=whpx,smm=on'
        $cpu = 'max'
    }
    'pc' {
        $machine = 'pc,accel=whpx'
        $cpu = 'host'
    }
    default { throw "unknown mode" }
}

$args = @(
    '-machine', $machine,
    '-cpu', $cpu,
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

Write-Host "mode=$Mode  machine=$machine  cpu=$cpu"
$p = Start-Process -FilePath $qemu -ArgumentList $args -WorkingDirectory 'C:\Program Files\qemu' -PassThru -WindowStyle Hidden
Start-Sleep -Seconds $Seconds
Write-Host ("qemu alive: " + (-not $p.HasExited))
if (Test-Path $serial) {
    Write-Host "--- serial tail ---"
    Get-Content $serial -Tail 18 -ErrorAction SilentlyContinue
} else { Write-Host "(no serial)" }
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Write-Host "stopped" }
