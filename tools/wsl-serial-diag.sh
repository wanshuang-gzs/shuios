#!/bin/sh
# 打印 shuios 虚拟机串口日志里的关键信息（用脚本避免 Windows 侧引号问题）。
set -u
LOG="${1:-/tmp/shuios-serial.log}"
if [ ! -f "$LOG" ]; then
	echo "(没有 $LOG)"
	exit 1
fi
echo "===== sshd / 网络 ====="
grep -a -e sshd -e eth0 -e DHCP -e networkd -e "link is" "$LOG" | tail -10
echo
echo "===== shuios-session / weston ====="
grep -a -e "shuios-session" -e "weston.log" -e "weston 退出" "$LOG" | tail -30
echo
echo "===== drm / bochs ====="
grep -a -e "drm" -e bochs -e "bochs-drm" "$LOG" | tail -10
echo
echo "===== 日志尾部 30 行 ====="
tail -n 30 "$LOG"
echo
echo "===== 大小 ====="
wc -c "$LOG"
