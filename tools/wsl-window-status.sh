#!/bin/sh
# 查看"窗口模式"那个 QEMU 实例的状态。
set -u
LOG=/tmp/shuios-window-serial.log
OUT=/tmp/qemu-window.out

echo "===== QEMU 进程 ====="
pgrep -a -f qemu-system-x86_64 | head -2 || echo "(没有进程)"

echo
echo "===== 显示后端 ====="
grep -a -o -e "gtk" "$OUT" 2>/dev/null | head -2 || true

echo
echo "===== 串口日志大小 ====="
wc -c "$LOG" 2>/dev/null || echo "(无日志)"

echo
echo "===== 启动关键行 ====="
grep -a -e "Started shuios" -e "Reached target Multi-User" -e "开机自检" -e "login:" "$LOG" 2>/dev/null | tail -8 || echo "(还没到)"

echo
echo "===== 自检段落 ====="
sed -n '/shuios 开机自检/,/^====/p' "$LOG" 2>/dev/null | head -30 || true

echo
echo "===== 串口尾部 ====="
tail -n 12 "$LOG" 2>/dev/null | tr -d '\r'
