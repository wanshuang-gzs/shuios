# Force a WSLg-hosted window (rendered by msrdc.exe) to appear on screen.
#
# Why: WSLg sometimes creates the window but leaves it offscreen or unfocused,
# which looks like "icon in taskbar but no window".
# NOTE: this file must stay pure ASCII (Windows PowerShell 5.1 reads .ps1 as ANSI
# when there is no BOM, and Chinese characters can swallow quotes).
param(
    [string]$TitleMatch = 'QEMU',
    [int]$Width = 1300,
    [int]$Height = 900,
    [int]$X = 80,
    [int]$Y = 60
)

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Win {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$targets = New-Object System.Collections.ArrayList
$found = 0
$cb = [Win+EnumProc]{
    param($h, $p)
    $len = [Win]::GetWindowTextLength($h)
    if ($len -gt 0) {
        $sb = New-Object System.Text.StringBuilder ($len + 2)
        [void][Win]::GetWindowText($h, $sb, $sb.Capacity)
        $t = $sb.ToString()
        if ($t -like "*$TitleMatch*") {
            $procId = 0
            [void][Win]::GetWindowThreadProcessId($h, [ref]$procId)
            $r = New-Object Win+RECT
            [void][Win]::GetWindowRect($h, [ref]$r)
            [void]$targets.Add([pscustomobject]@{
                Handle  = $h
                Title   = $t
                Pid     = $procId
                Visible = [Win]::IsWindowVisible($h)
                Rect    = "$($r.Left),$($r.Top) $($r.Right - $r.Left)x$($r.Bottom - $r.Top)"
            })
            $script:found++
        }
    }
    return $true
}
[void][Win]::EnumWindows($cb, [IntPtr]::Zero)

if ($targets.Count -eq 0) {
    Write-Host "No window title contains '$TitleMatch'."
    Get-Process msrdc -ErrorAction SilentlyContinue | Select-Object Id, MainWindowTitle | Format-Table -AutoSize
    exit 1
}

foreach ($t in $targets) {
    Write-Host ("found: pid={0} visible={1} rect=[{2}] title={3}" -f $t.Pid, $t.Visible, $t.Rect, $t.Title)
    [void][Win]::ShowWindow($t.Handle, 9)
    [void][Win]::SetWindowPos($t.Handle, [IntPtr]::Zero, $X, $Y, $Width, $Height, 0x0040)
    [void][Win]::SetForegroundWindow($t.Handle)
    Start-Sleep -Milliseconds 250
    $r2 = New-Object Win+RECT
    [void][Win]::GetWindowRect($t.Handle, [ref]$r2)
    Write-Host ("  moved to {0},{1} size {2}x{3} visible={4}" -f $r2.Left, $r2.Top, ($r2.Right - $r2.Left), ($r2.Bottom - $r2.Top), [Win]::IsWindowVisible($t.Handle))
}
