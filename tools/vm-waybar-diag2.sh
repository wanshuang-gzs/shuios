#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 相关进程 ##########"
$SSH 'for p in waybar dbus-daemon sway shui-panel; do printf "%-14s %s\n" "$p" "$(pgrep -x $p | tr "\n" " ")"; done'

echo
echo "########## dbus 装了吗 ##########"
$SSH 'ls -l /usr/bin/dbus-daemon /usr/bin/dbus-launch 2>&1 | head -3'

echo
echo "########## 会话里有没有 DBUS_SESSION_BUS_ADDRESS ##########"
$SSH 'tr "\0" "\n" < /proc/$(pgrep -x sway | head -1)/environ 2>/dev/null | grep -E "DBUS|WAYLAND|XDG_RUNTIME" | head -5'

echo
echo "########## 手动起 waybar 看日志 ##########"
$SSH 'D=$(ls /run/shuios/compositor | grep -m1 "^wayland-")
	export XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D
	if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -x /usr/bin/dbus-daemon ]; then
		DBUS_SESSION_BUS_ADDRESS=$(/usr/bin/dbus-daemon --session --fork --print-address)
		export DBUS_SESSION_BUS_ADDRESS
	fi
	nohup /usr/bin/waybar -l trace >/tmp/wb.log 2>&1 &
	sleep 4
	pgrep -x waybar >/dev/null && echo "waybar 存活" || echo "waybar 退出"
	echo "--- 日志尾部 ---"
	tail -12 /tmp/wb.log'
