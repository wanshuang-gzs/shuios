# shuios - resumable background downloader for the WSL runtime MSIX (ASCII only)
#
# Why: GitHub direct gives ~25 KB/s for this 519 MB bundle on this machine.
# Measured alternatives (2026-10-18): gh-proxy.com ~260 KB/s, ghproxy.net ~22 KB/s.
# The file is resumed with `curl -C -`, so mirrors can be mixed freely and the
# job can be killed/restarted at any time without losing progress.
#
# Output: D:\shuios\.cache\wsl\Microsoft.WSL.msixbundle
#         log: D:\shuios\.cache\wsl\fetch-wsl.log
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$dir = 'D:\shuios\.cache\wsl'
$out = Join-Path $dir 'Microsoft.WSL.msixbundle'
$log = Join-Path $dir 'fetch-wsl.log'
$done = Join-Path $dir 'fetch-wsl.done'
$asset = 'https://github.com/microsoft/WSL/releases/download/2.7.13/Microsoft.WSL_2.7.13.0_x64_ARM64.msixbundle'
$mirrors = @(
    ('https://gh-proxy.com/' + $asset),
    ('https://ghproxy.net/' + $asset),
    $asset
)
$expected = 518974350   # bytes from an earlier HEAD request

New-Item -ItemType Directory -Force -Path $dir | Out-Null
Remove-Item $done -ErrorAction SilentlyContinue

function Log($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding utf8
}

Log ("start; target=$expected bytes; mirrors=" + $mirrors.Count)

$maxRounds = 30
for ($round = 1; $round -le $maxRounds; $round++) {
    $size = 0
    if (Test-Path $out) { $size = (Get-Item $out).Length }
    if ($size -ge $expected) {
        Log ("complete: $size bytes")
        break
    }

    foreach ($m in $mirrors) {
        if (Test-Path $out) { $size = (Get-Item $out).Length }
        if ($size -ge $expected) { break }

        $host_ = ([uri]$m).Host
        Log ("round $round via $host_ from $size")

        & curl.exe -L --retry 2 --retry-delay 3 --speed-limit 2048 --speed-time 60 `
            -C - -o $out $m
        $rc = $LASTEXITCODE

        $size2 = 0
        if (Test-Path $out) { $size2 = (Get-Item $out).Length }
        Log ("  exit=$rc size=$size2")
        if ($size2 -ge $expected) { break }
    }

    if (Test-Path $out) { $size = (Get-Item $out).Length }
    if ($size -ge $expected) { break }
    Start-Sleep -Seconds 5
}

if ((Test-Path $out) -and ((Get-Item $out).Length -ge $expected)) {
    $h = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
    Log ("complete; sha256=$h")
    ('done ' + $h) | Set-Content $done -Encoding utf8
} else {
    $size = 0
    if (Test-Path $out) { $size = (Get-Item $out).Length }
    Log ("incomplete: $size / $expected")
    ('incomplete ' + $size) | Set-Content $done -Encoding utf8
}
