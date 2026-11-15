#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 用镜像自带的 config/CSS 手动跑，看报错 ##########"
$SSH 'D=$(ls /run/shuios/compositor | grep -m1 "^wayland-")
	export XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D
	if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -x /usr/bin/dbus-daemon ]; then
		DBUS_SESSION_BUS_ADDRESS=$(/usr/bin/dbus-daemon --session --fork --print-address)
		export DBUS_SESSION_BUS_ADDRESS
	fi
	nohup /usr/bin/waybar -l info >/tmp/wb-img.log 2>&1 &
	sleep 4
	pgrep -x waybar >/dev/null && echo "存活" || echo "退出"
	echo "--- 日志 ---"
	tail -15 /tmp/wb-img.log'

echo
echo "########## config 是否是合法 JSON ##########"
$SSH 'jq . /etc/xdg/waybar/config >/dev/null 2>&1 && echo "JSON 合法" || jq -r "." /etc/xdg/waybar/config 2>&1 | head -3'
