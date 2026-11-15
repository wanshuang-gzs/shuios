﻿﻿﻿﻿﻿﻿﻿﻿﻿﻿﻿﻿﻿# 对照实验：用与 shuios 完全相同的虚拟化配置跑 Ubuntu 官方桌面
# 目的：隔离变量——同样卡 → 虚拟化链路问题；流畅 → shuios UI 栈问题
# 配置镜像 run-vm.ps1：WHPX + Haswell,-vmx + virtio-gpu + SDL + usb-tablet
param(
    [string]$Iso = 'D:\shuios\.cache\ubuntu-26.04.1-desktop-amd64.iso',
    [int]$MemoryMb = 4096,
    [int]$Cpus = 4,
    [string]$CpuModel = 'Haswell,-vmx',
    [switch]$NoWait
)

$qemu = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
if (-not (Test-Path $Iso)) { throw "ISO not found: $Iso" }

$ovmfDir = 'D:\shuios\.cache\ovmf'
$code = Join-Path $ovmfDir 'OVMF_CODE_4M.fd'
$varsSrc = Join-Path $ovmfDir 'OVMF_VARS_4M.fd'
$vars = Join-Path $ovmfDir 'OVMF_VARS_ubuntu.fd'   # 独立 VARS，避免和 shuios VM 抢锁
if (-not (Test-Path $vars)) { Copy-Item $varsSrc $vars }
Remove-Item "$vars.qemu-lock*" -ErrorAction SilentlyContinue

# 端口避开 shuios VM（5555/5556/10022 被占）
$qa = @(
    '-machine','q35,accel=whpx',
    '-cpu',"$CpuModel",
    '-m',"$MemoryMb",'-smp',"$Cpus",
    '-drive',"if=pflash,format=raw,readonly=on,file=$code",
    '-drive',"if=pflash,format=raw,file=$vars",
    # bootindex 强制 OVMF 从光盘启动（-boot d 对 OVMF 不可靠，实测掉进 PXE）
    '-drive',"file=$Iso,media=cdrom,if=none,id=cd0,readonly=on",
    '-device','ide-cd,drive=cd0,bootindex=0',
    '-netdev','user,id=n0',
    '-device','e1000,netdev=n0',
    '-device','qemu-xhci,id=xhci',
    '-device','usb-tablet,bus=xhci.0',
    # virtio-vga：VGA 兼容形态，发行版 GRUB→内核显示交接才正常；
    # 设备模型和 virtio-gpu-pci 完全一样（guest 里都是 virtio_gpu + llvmpipe），对照依然公平
    '-device','virtio-vga',
    '-display','sdl',
    '-name','ubuntu-control-test',
    '-monitor','tcp:127.0.0.1:5565,server,nowait',
    '-chardev','file,id=ser0,path=D:\shuios\.cache\ubuntu-serial.log',
    '-serial','chardev:ser0'
)

Write-Host "starting Ubuntu control VM  accel=whpx cpu=$CpuModel mem=${MemoryMb}MB"
Write-Host "  iso: $Iso"
Write-Host "  monitor: 127.0.0.1:5565"
if ($NoWait) {
    Start-Process -FilePath $qemu -ArgumentList $qa -WorkingDirectory 'C:\Program Files\qemu'
    Write-Host "launched in background"
} else {
    & $qemu @qa
}
