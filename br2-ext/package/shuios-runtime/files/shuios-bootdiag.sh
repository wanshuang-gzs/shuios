#!/bin/sh
# shuios 开机自检：把关键状态写到串口（/dev/ttyS0），便于无头排障。
#
# 为什么需要：虚拟机里没有 SSH（比如网络还没起来）时，只能靠串口看状态。
# 这个脚本是 shuios 开发过程里最有用的排障工具之一。
set -u
SER=/dev/ttyS0
[ -w "$SER" ] || SER=/dev/console

{
	echo
	echo "================ shuios 开机自检 ================"
	echo "内核: $(uname -r)"
	echo "启动耗时: $(cut -d' ' -f1 /proc/uptime 2>/dev/null) 秒"
	echo
	echo "--- 网卡设备 ---"
	ls /sys/class/net 2>/dev/null | tr '\n' ' '
	echo
	echo "--- 地址 ---"
	ip -br addr 2>/dev/null || echo "(ip 命令不可用)"
	echo
	echo "--- 显示设备 ---"
	ls /dev/dri 2>/dev/null | tr '\n' ' '
	echo
	echo "--- 关键服务 ---"
	for u in seatd shuios-desktop shuiosd shuios-llama sshd systemd-networkd; do
		state=$(systemctl is-active "$u" 2>/dev/null)
		echo "  $u: ${state:-unknown}"
	done
	echo
	echo "--- 失败的单元 ---"
	systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null | head -8 || echo "  （无）"
	echo
	echo "--- 挂载 ---"
	grep -E ' (/|/workspace|/data|/var/lib/shuios) ' /proc/mounts 2>/dev/null | awk '{print "  " $2 " <- " $1 " (" $3 ", " $4 ")"}'
	echo "================================================="
	echo
} >> "$SER" 2>/dev/null || true
