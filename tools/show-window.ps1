# 把 WSLg 里的某个窗口强制显示到前台并摆到屏幕内。
#
# 背景：WSLg 通过 msrdc.exe 渲染 Linux 窗口。偶尔窗口被创建但位于屏幕外、
# 或者没有前台焦点，表现为"任务栏有图标但看不到窗口"。
# 这里用 Win32 API 把它 ShowWindow + SetWindowPos + SetForegroundWindow。
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
$cb = [Win+EnumProc]{
    param($h, $p)
    $len = [Win]::GetWindowTextLength($h)
    if ($len -gt 0) {
        $sb = New-Object System.Text.StringBuilder ($len + 2)
        [void][Win]::GetWindowText($h, $sb, $sb.Capacity)
        $t = $sb.ToString()
        if ($t -like "*$TitleMatch*") {
            $pid_ = 0
            [void][Win]::GetWindowThreadProcessId($h, [ref]$pid_)
            $r = New-Object Win+RECT
            [void][Win]::GetWindowRect($h, [ref]$r)
            [void]$targets.Add([pscustomobject]@{
                Handle = $h; Title = $t; Pid = $pid_
                Visible = [Win]::IsWindowVisible($h)
                Rect = "$($r.Left),$($r.Top) $($r.Right - $r.Left)x$($r.Bottom - $r.Top)"
            })
        }
    }
    return $true
}
[void][Win]::EnumWindows($cb, [IntPtr]::Zero)

if ($targets.Count -eq 0) {
    Write-Host "没有找到标题里含 '$TitleMatch' 的窗口。"
    Write-Host "（可能窗口还没创建，等几秒再试；或 WSLg 的 msrdc 进程不在）"
    Get-Process msrdc -ErrorAction SilentlyContinue | Select-Object Id, MainWindowTitle | Format-Table -AutoSize
    exit 1
}

foreach ($t in $targets) {
    Write-Host ("找到窗口: pid={0} visible={1} rect=[{2}] 标题={3}" -f $t.Pid, $t.Visible, $t.Rect, $t.Title)
    [void][Win]::ShowWindow($t.Handle, 9)          # SW_RESTORE
    [void][Win]::SetWindowPos($t.Handle, [IntPtr]::Zero, $X, $Y, $Width, $Height, 0x0040)
    [void][Win]::SetForegroundWindow($t.Handle)
    Start-Sleep -Milliseconds 200
    $r2 = New-Object Win+RECT
    [void][Win]::GetWindowRect($t.Handle, [ref]$r2)
    Write-Host ("  已移动到 {0},{1} 尺寸 {2}x{3}，visible={4}" -f $r2.Left, $r2.Top, ($r2.Right - $r2.Left), ($r2.Bottom - $r2.Top), [Win]::IsWindowVisible($t.Handle))
}
