param(
    [string]$Image = 'D:\shuios\shuios.img',
    [int]$MemoryMb = 4096,
    [int]$Cpus = 4,
    [switch]$Tcg,
    [switch]$NoWait,
    # 显卡默认 bochs VGA（-vga std）。实测（2026-10-27，WHPX + llvmpipe）：
    #   virtio-gpu 2D 下 QEMU 侧 surface 只收到脏矩形的局部传输，新资源没传到的
    #   区域是黑的 —— 屏幕上就是"区域黑块"：冷启动后反复出现、持续数秒到数分钟、
    #   64 像素对齐，8 帧采样最坏 12256 px。同一镜像换 bochs：黑块 0 像素，
    #   鼠标移出再移回后桌面变化 0 像素。
    # 要 3D 用 -Gl；要复现 virtio-gpu 2D 的问题才加 -Virtio。
    [switch]$Virtio,
    # -Gl：给 virtio-gpu 开 3D（virgl），把 GLES 交给宿主 GPU。
    # 不开时 guest 走 mesa 的 kms_swrast（llvmpipe 软件光栅化），
    # 1280x800 全帧合成 + 软件光标就是"页面卡顿"的来源。
    # 前提：guest 侧已就绪（CONFIG_VIRTIO_GPU=y +  mesa 的 virtio/gallium 驱动），
    # host 侧 QEMU 带 libvirglrenderer-1.dll（本机已确认）。
    # 注意本机实测：QEMU 11.1 走 virgl 呈现时崩在 NVIDIA 的 nvoglv64.dll
    # （0xc0000005，Windows 应用程序日志可查），所以默认不开，仅作对照。
    [switch]$Gl,
    # 显示后端：sdl = 交互手感最好（默认）；
    # gtk = 自动化截图/视觉验证用，不会被遮挡导致的 Present 阻塞冻屏
    [ValidateSet('sdl', 'gtk', 'none')]
    [string]$Display = 'sdl'
)

$qemu = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
if (-not (Test-Path $qemu)) { throw "QEMU not found: $qemu" }
if (-not (Test-Path $Image)) { throw "Image not found: $Image" }

# 注意：Win32_Processor.VirtualizationFirmwareEnabled 在 Hyper-V hypervisor
# 已运行时会误报 False（VT-x 被 hypervisor 屏蔽），不要拿它判断 BIOS 设置。
# 本项目宿主机 VT-x 已开启（WSL2 可用即证明），直接上 WHPX。
$ovmfDir = 'D:\shuios\.cache\ovmf'
$code = Join-Path $ovmfDir 'OVMF_CODE_4M.fd'
$varsSrc = Join-Path $ovmfDir 'OVMF_VARS_4M.fd'
$vars = Join-Path $ovmfDir 'OVMF_VARS_run.fd'
if (-not (Test-Path $code)) { throw "OVMF code not found: $code" }
if (-not (Test-Path $vars)) { Copy-Item $varsSrc $vars }

$serial = 'D:\shuios\.cache\win-vm-serial.log'
Remove-Item $serial -ErrorAction SilentlyContinue
Remove-Item "$vars.qemu-lock*" -ErrorAction SilentlyContinue

# 默认 WHPX 硬件加速（Windows Hypervisor Platform），-Tcg 手动降级纯软件模拟。
# CPU 型号踩坑记录：
#   '-cpu max'    → OVMF PEI 阶段访问 MSR 0x3A (IA32_FEATURE_CONTROL) #GP 三反
#   '-cpu qemu64' → 能跑但只有 SSE2，llvmpipe 没 AVX2 渲染很慢
#   'Haswell,-vmx'→ AVX2/BMI2 可用（llvmpipe 满血），关 vmx 避开 MSR 0x3A 坑，实测稳
$accel = if ($Tcg) { 'tcg' } else { 'whpx' }

# 注意：不能用 $args 做数组变量名——它是 PowerShell 自动变量！
$qa = @()
$qa += @('-machine', "q35,accel=$accel")
$qa += @('-cpu', 'Haswell,-vmx')
$qa += @('-m', "$MemoryMb")
$qa += @('-smp', "$Cpus")
$qa += @('-drive', "if=pflash,format=raw,readonly=on,file=$code")
$qa += @('-drive', "if=pflash,format=raw,file=$vars")
$qa += @('-drive', "file=$Image,format=raw,if=ide,index=0")
$qa += @('-netdev', 'user,id=n0,hostfwd=tcp:0.0.0.0:10022-:22')
$qa += @('-device', 'e1000,netdev=n0')
# USB 输入设备：
#   注意 qemu-xhci + usb-tablet 在 QEMU 11.1 上会让 guest 在 GRUB 交接内核后卡死
#   （串口停在 "Booting ..."、窗口 Not Responding，Ubuntu 对照组同样复现）。
#   改用 usb-ehci + usb-tablet 实测稳定（多次冷启动均正常）。
$qa += @('-device', 'usb-ehci,id=ehci')
$qa += @('-device', 'usb-tablet,bus=ehci.0')
# SDL 后端在 Windows 上默认走 D3D + PRESENTVSYNC；当 QEMU 窗口被其他窗口遮挡
# 或处于后台时，Present 可能长时间阻塞 QEMU 主循环，导致 virtio-gpu 的
# resource_flip 响应发不出去 → guest 合成器等 flip 完成事件永久挂起（画面冻结）。
# 关掉 vsync 可避免该阻塞（画面可能轻微撕裂，但不会冻屏）。
# 开 3D（-Gl）时不关：那时翻页由宿主 GPU 排期，关掉只会白白引入撕裂，
# 而撕裂看上去正是"鼠标一闪一闪、画面局部闪"。
if (-not $Gl) {
    $env:SDL_HINT_RENDER_VSYNC = '0'
}

if ($Gl) {
    # guest 里 mesa 的 virtio(virgl) 驱动把 GLES 调用转给宿主 GPU，
    # 不再用 llvmpipe 软件光栅化整屏。
    # 设备名必须是 virtio-gpu-gl-pci：本构建的 virtio-gpu-pci 没有 gl 属性
    # （报 "Property 'virtio-gpu-pci.gl' not found"），3D 是独立的 gl 机型。
    $qa += @('-vga', 'none', '-device', 'virtio-gpu-gl-pci')
} elseif ($Virtio) {
    # 2D virtio-gpu：留着做对照/复现黑块用，不做默认。
    $qa += @('-vga', 'none', '-device', 'virtio-gpu-pci')
} else {
    # bochs VGA：QEMU 直接读 guest 的线性帧缓冲，没有 virtio 那套
    # "按脏矩形把 BO 传给宿主"的路径，因此不会出现上面说的黑块。
    $qa += @('-vga', 'std')
}
# SDL 后端：host 端 Direct3D 纹理 + 垂直同步，比 GTK-Windows 的软件重绘流畅得多；
# GTK 后端在 Windows 上刷新率/延迟都很差（这正是"guest 很快但窗口里卡"的根因）。
# 注意本构建的 SDL 不支持 zoom-to-fit 子选项（窗口缩放它自己处理）。
$disp = $Display
if ($Gl -and ($Display -ne 'none')) {
    # 显示后端也要开 gl，与设备侧成对，否则 QEMU 直接报错退出
    $disp = "$Display,gl=on"
}
$qa += @('-display', $disp)
$qa += @('-name', 'shuios-0.1')
$qa += @('-monitor', 'tcp:127.0.0.1:5555,server,nowait')
$qa += @('-qmp', 'tcp:127.0.0.1:5556,server,nowait')
$qa += @('-chardev', "file,id=ser0,path=$serial")
$qa += @('-serial', 'chardev:ser0')

Write-Host "starting QEMU  accel=$accel  mem=${MemoryMb}MB  cpus=$Cpus"
Write-Host "  image : $Image"
Write-Host "  serial: $serial"
Write-Host "  ssh   : ssh -p 10022 root@127.0.0.1  (password: shui)"
Write-Host "  gpu   : $(if ($Gl) { 'virtio-gpu-gl-pci (virgl -> 宿主 GPU，本机 NVIDIA 驱动会崩)' } elseif ($Virtio) { 'virtio-gpu-pci 2D (llvmpipe；有黑块，仅对照用)' } else { 'bochs VGA (llvmpipe；实测无黑块无残影)' })"
Write-Host "  display: $disp  vsync=$(if ($Gl) { 'on' } else { 'off' })"
Write-Host "  total args: $($qa.Count)"

if ($NoWait) {
    Start-Process -FilePath $qemu -ArgumentList $qa -WorkingDirectory 'C:\Program Files\qemu'
    Write-Host "launched in background"
} else {
    & $qemu @qa
}
