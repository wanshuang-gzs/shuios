# shuios - install the WSL runtime MSIX (ASCII only, must be elevated)
#
# Prerequisite: D:\shuios\.cache\wsl\Microsoft.WSL.msixbundle
#   (produced by tools\fetch-wsl-msix.ps1, resumable, ~495 MB)
#
# Why not `wsl --install`: on Windows 11 Home 26200 the inbox wsl.exe refuses
# ("Windows Subsystem for Linux has not been installed") and the Store paths
# fail with 0x80073D21, so we install the signed MSIX ourselves.
$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'

$logDir = 'D:\shuios\.cache'
$wslDir = Join-Path $logDir 'wsl'
$log    = Join-Path $logDir 'wsl-msix.log'
$done   = Join-Path $logDir 'wsl-msix.done'
$msix   = Join-Path $wslDir 'Microsoft.WSL.msixbundle'
$expected = 518974350

Remove-Item $done -ErrorAction SilentlyContinue
"==== shuios WSL MSIX install $(Get-Date -Format o) ====" | Set-Content -Path $log -Encoding utf8
function Log($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding utf8
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
$isAdmin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log ("user=" + $id.Name + " is_admin=" + $isAdmin)
if (-not $isAdmin) {
    Log 'ERROR: not an elevated session'
    'not-admin' | Set-Content $done -Encoding utf8
    exit 1
}

if (-not (Test-Path $msix)) {
    Log ("ERROR: missing $msix (run tools\fetch-wsl-msix.ps1 first)")
    'no-msix' | Set-Content $done -Encoding utf8
    exit 1
}
$size = (Get-Item $msix).Length
Log ("msix size=$size expected=$expected")
if ($size -lt $expected) {
    Log 'ERROR: incomplete download, resume it first'
    'incomplete' | Set-Content $done -Encoding utf8
    exit 1
}
Log ("sha256=" + (Get-FileHash $msix -Algorithm SHA256).Hash.ToLower())

Log '--- 1/3 Add-AppxPackage (per-machine) ---'
try {
    Add-AppxPackage -Path $msix -ForceApplicationShutdown -ErrorAction Stop
    Log 'Add-AppxPackage ok'
} catch {
    Log ("Add-AppxPackage failed: " + $_.Exception.Message)
    Log '--- retry with -ForceUpdateFromAnyVersion ---'
    try {
        Add-AppxPackage -Path $msix -ForceApplicationShutdown -ForceUpdateFromAnyVersion -ErrorAction Stop
        Log 'Add-AppxPackage (force) ok'
    } catch {
        Log ("force failed: " + $_.Exception.Message)
    }
}

Log '--- 2/3 wsl --version ---'
cmd /c ('wsl.exe --version >> "' + $log + '" 2>&1 < NUL')
Log ("version exit=" + $LASTEXITCODE)

Log '--- 3/3 wsl --set-default-version 2 ---'
cmd /c ('wsl.exe --set-default-version 2 >> "' + $log + '" 2>&1 < NUL')
Log ("set-default exit=" + $LASTEXITCODE)

$prog = Test-Path 'C:\Program Files\WSL'
Log ("C:\Program Files\WSL exists=" + $prog)
if ($prog) { 'ok' | Set-Content $done -Encoding utf8 } else { 'failed' | Set-Content $done -Encoding utf8 }
Log '==== done ===='
