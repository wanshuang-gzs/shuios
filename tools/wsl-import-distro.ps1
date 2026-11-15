# shuios - step 2: import the build distro to D: (ASCII only, normal user, no UAC)
#
# Downloads the Ubuntu 24.04 cloud rootfs from the TUNA mirror (fast in China)
# and imports it as a WSL2 distro rooted on D:\wsl so the system disk is not
# filled up by a Buildroot build.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:WSL_UTF8 = '1'

$logDir = 'D:\shuios\.cache'
$wslDir = 'D:\wsl'
$name   = 'shui-build'
$tar    = Join-Path $wslDir 'cache\noble-rootfs.tar.xz'
$root   = Join-Path $wslDir $name
$log    = Join-Path $logDir 'wsl-import.log'

New-Item -ItemType Directory -Force -Path $logDir, (Join-Path $wslDir 'cache') | Out-Null
"==== shuios distro import $(Get-Date -Format o) ====" | Set-Content -Path $log -Encoding utf8

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $log -Value $line -Encoding utf8
}

# 1) Skip when already imported
$existing = & wsl.exe -l -q 2>$null
if ($existing) {
    $names = $existing -split "`n" | ForEach-Object { ($_ -replace "`0", '').Trim() }
    if ($names -contains $name) {
        Log "distro '$name' already imported"
        Log '== DONE =='
        exit 0
    }
}

# 2) Download the rootfs
$url = 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images/noble/current/noble-server-cloudimg-amd64-root.tar.xz'
if (-not (Test-Path $tar) -or (Get-Item $tar).Length -lt 50MB) {
    Log "downloading $url"
    & curl.exe -L --retry 3 --max-time 1800 -o $tar $url
    if ($LASTEXITCODE -ne 0) { Log "download FAILED exit=$LASTEXITCODE"; exit 1 }
}
Log ("rootfs size=" + [math]::Round((Get-Item $tar).Length/1MB,1) + " MB")

# 3) Import into D:
if (Test-Path $root) { Remove-Item -Recurse -Force $root }
New-Item -ItemType Directory -Force -Path $root | Out-Null
Log "importing as '$name' -> $root"
& wsl.exe --import $name $root $tar --version 2
if ($LASTEXITCODE -ne 0) { Log "import FAILED exit=$LASTEXITCODE"; exit 1 }

# 4) Minimal wsl.conf (ASCII content only)
$wslConf = Join-Path $root 'etc\wsl.conf'
$lines = @(
    '[boot]',
    'systemd=false',
    '[user]',
    'default=root',
    '[interop]',
    'enabled=false',
    'appendWindowsPath=false',
    '[automount]',
    'enabled=true',
    'options=metadata,umask=22,fmask=11'
)
Set-Content -Path $wslConf -Value $lines -Encoding ascii

Log '--- wsl -l -v ---'
& wsl.exe -l -v 2>&1 | Out-File -Append -Path $log -Encoding utf8

Log '== DONE =='
