#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

$SSH 'pkill -x waybar; sleep 1
	D=$(ls /run/shuios/compositor | grep -m1 "^wayland-")
	export XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D
	export LANG=C.UTF-8 LC_ALL=C.UTF-8
	if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -x /usr/bin/dbus-daemon ]; then
		DBUS_SESSION_BUS_ADDRESS=$(/usr/bin/dbus-daemon --session --fork --print-address)
		export DBUS_SESSION_BUS_ADDRESS
	fi
	nohup /usr/bin/waybar -l info >/tmp/wb-lang.log 2>&1 &
	sleep 4
	pgrep -x waybar >/dev/null && echo "waybar 存活" || echo "waybar 退出"
	echo "--- 日志 ---"
	grep -E "error|warning|Bar configured|Disabling" /tmp/wb-lang.log | tail -8'
