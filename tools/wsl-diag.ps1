# shuios - WSL diagnostics (ASCII only, must be elevated)
$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'
$logDir = 'D:\shuios\.cache'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'wsl-diag.log'
"==== shuios WSL diagnostics $(Get-Date -Format o) ====" | Set-Content -Path $log -Encoding utf8

function Run($title, $cmdline) {
    Add-Content -Path $log -Value ("`n---- " + $title + " ----") -Encoding utf8
    cmd /c ($cmdline + ' >> "' + $log + '" 2>&1 < NUL')
    Add-Content -Path $log -Value ("exit=" + $LASTEXITCODE) -Encoding utf8
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
Add-Content -Path $log -Value ("user=" + $id.Name + " is_admin=" + $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) -Encoding utf8

Run 'featureinfo Microsoft-Windows-Subsystem-Linux' 'dism /online /get-featureinfo /featurename:Microsoft-Windows-Subsystem-Linux'
Run 'featureinfo VirtualMachinePlatform' 'dism /online /get-featureinfo /featurename:VirtualMachinePlatform'
Run 'features list (filtered)' 'dism /online /get-features /format:table | findstr /i "Linux VirtualMachine"'
Run 'sc query lxss' 'sc query lxss'
Run 'sc query LxssManager' 'sc query LxssManager'
Run 'sc query WslService' 'sc query WslService'
Run 'wsl --install --no-distribution' 'wsl.exe --install --no-distribution'
Run 'wsl --status' 'wsl.exe --status'

Add-Content -Path $log -Value '==== done ====' -Encoding utf8
'should-be-enabled' | Set-Content (Join-Path $logDir 'wsl-diag.done') -Encoding utf8
