param(
    [string]$Image = 'D:\shuios\shuios.img',
    [string]$VmDir = 'D:\shuios\.cache\vmware',
    [switch]$Reconvert,
    [switch]$NoStart,
    [switch]$Stop
)

# VMware 侧启动脚本：把 raw 镜像转成 vmdk 后用 Workstation 启动。
# 用途：对照 QEMU/virtio-gpu，验证 vmwgfx 这条 DRM 路径下的渲染与性能。

$ws = 'C:\Program Files (x86)\VMware\VMware Workstation'
$vdm = Join-Path $ws 'vmware-vdiskmanager.exe'
$vmrun = Join-Path $ws 'vmrun.exe'
$vmx = Join-Path $VmDir 'shuios.vmx'
$vmdk = Join-Path $VmDir 'shuios.vmdk'

foreach ($p in @($vdm, $vmrun, $vmx)) {
    if (-not (Test-Path $p)) { throw "missing: $p" }
}
if (-not (Test-Path $Image)) { throw "image not found: $Image" }
if (-not (Test-Path $VmDir)) { New-Item -ItemType Directory -Path $VmDir | Out-Null }

# 停虚拟机：vmrun stop soft 之后必须等进程真正退出，否则会拿旧盘启动
# （踩过：-Reconvert 时 VM 还开着，Remove-Item 抢不到文件，qemu-img 覆盖了
# 正在使用的 vmdk，随后的 start 因为 VM 已在运行而空转，串口日志还是上一次的）。
function Stop-Vm([string]$reason) {
    $running = (& $vmrun -T ws list 2>&1 | Out-String) -match [regex]::Escape($vmx)
    if (-not $running) { return $true }
    Write-Host "$reason - stopping the running VM first"
    & $vmrun -T ws stop $vmx soft 2>&1 | Out-String | Write-Host
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        $running = (& $vmrun -T ws list 2>&1 | Out-String) -match [regex]::Escape($vmx)
        if (-not $running) { return $true }
    }
    Write-Host "soft stop timed out, forcing power off"
    & $vmrun -T ws stop $vmx hard 2>&1 | Out-String | Write-Host
    Start-Sleep -Seconds 5
    return -not ((& $vmrun -T ws list 2>&1 | Out-String) -match [regex]::Escape($vmx))
}

if ($Stop) {
    & $vmrun -T ws stop $vmx soft 2>&1 | Out-String | Write-Host
    Write-Host "stopped"
    return
}

# ---- 硬性键值：3D 加速 + 声卡，每次启动前钉住 ------------------------------
# 3D：guest 的 vmwgfx 不实现 dumb buffer，宿主机不开 3D 时 mesa 建不出 EGL screen
# （串口日志 "VMware: No 3D enabled" → "failed to create dri2 screen"），swayfx
# 直接退出，会话掉进 Weston 兜底——Weston 没有 wlr-layer-shell，waybar / Dock
# 全起不来，而且它的软件合成会在指针周围留下黑块和残影。
# 声卡：手搓的 .vmx 默认没有 sound.present，guest 里 /proc/asound/cards 是空的。
# hdaudio 是 Workstation 8+ 的默认虚拟设备；镜像内核已内置 HDA codec。
# 手搓的 .vmx 很容易把 mks.enable3d 写回 FALSE，所以每次启动前校正一次。
$wantKeys = [ordered]@{
    'memsize'               = '8192'
    'numvcpus'              = '6'
    'mks.enable3d'          = 'TRUE'
    'svga.autodetect'       = 'FALSE'
    'svga.vramSize'         = '134217728'
    'floppy0.present'       = 'FALSE'
    'sound.present'         = 'TRUE'
    'sound.virtualDev'      = 'hdaudio'
    'sound.autodetect'      = 'TRUE'
    'sound.startConnected'  = 'TRUE'
}
# 转换用；顺便在改键之前先把 VM 停掉（VMware 退出时会用自己的内存副本覆写 vmx，
# 所以停必须在写之前）。
$qemuImg = 'C:\Program Files\qemu\qemu-img.exe'
$needConvert = $Reconvert -or (-not (Test-Path $vmdk)) -or
    ((Get-Item $vmdk).LastWriteTime -lt (Get-Item $Image).LastWriteTime)
if ($needConvert) {
    if (-not (Stop-Vm "image changed")) { throw "cannot stop the running VM" }
}
# 注意：用 .NET 读写而不是 Get-Content | Set-Content（PS 5.1 会加 BOM，
# VMware 解析 .vmx 时不认）。
$lines = [System.IO.File]::ReadAllLines($vmx)
$hit = @{}
$fixed = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    $k = ($lines[$i] -split '=')[0].Trim()
    if ($wantKeys.Contains($k)) {
        $want = "$k = `"$($wantKeys[$k])`""
        $hit[$k] = $true
        if ($lines[$i].Trim() -ne $want) { $lines[$i] = $want; $fixed += $k }
    }
}
foreach ($k in $wantKeys.Keys) {
    if (-not $hit[$k]) { $lines += "$k = `"$($wantKeys[$k])`""; $fixed += $k }
}
if ($fixed.Count -gt 0) {
    # 正在跑的虚拟机会在退出时用自己的内存副本覆写 .vmx，所以必须先停再改
    if (-not (Stop-Vm "vmx needs keys ($($fixed -join ', '))")) {
        throw "cannot stop the running VM"
    }
    [System.IO.File]::WriteAllLines($vmx, $lines, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已写入 VMX 键：$($fixed -join ', ')"
}

# 转换：raw -> VMDK。
# 注意：vmware-vdiskmanager -r 只接受 VMware 自己的磁盘文件，不接受裸镜像，
# 所以这里用 QEMU 自带的 qemu-img 转（产出的 VMDK 与 Workstation 兼容）。
if ($needConvert) {
    if (-not (Test-Path $qemuImg)) { throw "qemu-img not found: $qemuImg" }
    if (-not (Stop-Vm "image changed")) { throw "cannot stop the running VM" }
    if (Test-Path $vmdk) {
        for ($i = 0; $i -lt 10; $i++) {
            try { Remove-Item $vmdk -Force -ErrorAction Stop; break }
            catch { Start-Sleep -Seconds 2 }
        }
        if (Test-Path $vmdk) { throw "vmdk is still locked: $vmdk" }
    }
    Write-Host "converting raw -> vmdk (this reads the whole image)"
    & $qemuImg convert -p -f raw -O vmdk -o subformat=monolithicSparse $Image $vmdk
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $vmdk)) { throw "vmdk conversion failed" }
} else {
    Write-Host "vmdk is up to date"
}

if ($NoStart) { Write-Host "skip start"; return }

# 串口文件已存在时 VMware 会弹「替换/附加」模态框，VM 卡在那里不启动。
# 每次启动前把它挪开，保证开机后串口日志是干净的一份。
$serialLog = 'D:\shuios\.cache\vmware-serial.log'
if (Test-Path $serialLog) { Move-Item $serialLog "$serialLog.prev" -Force }

Write-Host "starting VMware VM: $vmx"
& $vmrun -T ws start $vmx 2>&1 | Out-String | Write-Host
Write-Host "serial log: D:\shuios\.cache\vmware-serial.log"
Write-Host "tip: stop with  tools\run-vmware.ps1 -Stop"
