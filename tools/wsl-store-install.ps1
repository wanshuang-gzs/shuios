# shuios - try installing the WSL runtime from the Microsoft Store channel (ASCII, elevated)
$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'
$logDir = 'D:\shuios\.cache'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'wsl-store.log'
$done = Join-Path $logDir 'wsl-store.done'
Remove-Item $done -ErrorAction SilentlyContinue
"==== shuios WSL store install $(Get-Date -Format o) ====" | Set-Content -Path $log -Encoding utf8

function Log($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
Log ("is_admin=" + $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

Log '--- attempt 1: msstore product id 9P9TQF7MRM4R ---'
$c = 'winget install --id 9P9TQF7MRM4R --source msstore --accept-package-agreements --accept-source-agreements --disable-interactivity >> "' + $log + '" 2>&1 < NUL'
cmd /c $c
Log ("msstore exit=" + $LASTEXITCODE)

$wsl = Test-Path 'C:\Program Files\WSL'
Log ("C:\Program Files\WSL exists=" + $wsl)

if (-not $wsl) {
    Log '--- attempt 2: winget source winget (github mirror) ---'
    $c2 = 'winget install --id Microsoft.WSL --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity >> "' + $log + '" 2>&1 < NUL'
    cmd /c $c2
    Log ("winget exit=" + $LASTEXITCODE)
    $wsl = Test-Path 'C:\Program Files\WSL'
    Log ("C:\Program Files\WSL exists=" + $wsl)
}

Log '--- wsl --version ---'
cmd /c ('wsl.exe --version >> "' + $log + '" 2>&1 < NUL')
Log ("version exit=" + $LASTEXITCODE)

if ($wsl) { 'ok' | Set-Content $done -Encoding utf8 } else { 'incomplete' | Set-Content $done -Encoding utf8 }
Log '==== done ===='
