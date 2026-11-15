# shuios - step 1 after reboot: install the WSL2 runtime (ASCII only, must be elevated)
#
# Run this AFTER a reboot has activated the WSL / VirtualMachinePlatform
# optional features. Then run tools\wsl-import-distro.ps1 (normal user).
$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'

$logDir = 'D:\shuios\.cache'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log  = Join-Path $logDir 'wsl-post-reboot.log'
$done = Join-Path $logDir 'wsl-post-reboot.done'

Remove-Item $done -ErrorAction SilentlyContinue
"==== shuios WSL runtime install $(Get-Date -Format o) ====" | Set-Content -Path $log -Encoding utf8

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Add-Content -Path $log -Value $line -Encoding utf8
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
Log ("user=" + $id.Name + " is_admin=" + $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

$pending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
Log ("reboot pending=" + $pending)

Log '--- 1/4 wsl --install --no-distribution (Store path, usually fastest in CN) ---'
$c1 = 'wsl.exe --install --no-distribution >> "' + $log + '" 2>&1 < NUL'
cmd /c $c1
$rc = $LASTEXITCODE
Log ("install(store) exit=" + $rc)
if ($rc -ne 0) {
    Log '--- fallback: wsl --install --no-distribution --web-download (GitHub) ---'
    $c1b = 'wsl.exe --install --no-distribution --web-download >> "' + $log + '" 2>&1 < NUL'
    cmd /c $c1b
    Log ("install(web) exit=" + $LASTEXITCODE)
}

Log '--- 2/4 wsl --update --web-download ---'
$c2 = 'wsl.exe --update --web-download >> "' + $log + '" 2>&1 < NUL'
cmd /c $c2
Log ("update exit=" + $LASTEXITCODE)

Log '--- 3/4 wsl --set-default-version 2 ---'
$c3 = 'wsl.exe --set-default-version 2 >> "' + $log + '" 2>&1 < NUL'
cmd /c $c3
Log ("set-default exit=" + $LASTEXITCODE)

Log '--- 4/4 wsl --version ---'
$c4 = 'wsl.exe --version >> "' + $log + '" 2>&1 < NUL'
cmd /c $c4
Log ("version exit=" + $LASTEXITCODE)

$progDir = Test-Path 'C:\Program Files\WSL'
Log ("C:\Program Files\WSL exists=" + $progDir)

if ($progDir) { 'ok' | Set-Content $done -Encoding utf8 }
else { 'incomplete' | Set-Content $done -Encoding utf8 }

Log '==== done ===='
