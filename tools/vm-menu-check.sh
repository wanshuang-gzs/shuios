#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 镜像里的桌面脚本关键行 ##########"
$SSH 'grep -n "AUTOSTART\|shui-store\|shui-panel" /usr/libexec/shuios/shuios-desktop'

echo
echo "########## 商店进程的来历 ##########"
$SSH 'ps -o pid,ppid,etimes,args -e 2>/dev/null | grep -E "shui-store|shui-panel" | grep -v grep'

echo
echo "########## 商店日志 ##########"
$SSH 'head -6 /tmp/shui-store.log 2>/dev/null || echo "(无日志)"'

echo
echo "########## 用镜像里的路径打开开始菜单 ##########"
D=$($SSH 'ls /run/shuios/compositor 2>/dev/null | grep -m1 "^wayland-"')
$SSH "XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D \
	nohup /usr/bin/shui-panel --menu >/tmp/menu4.log 2>&1 &
	sleep 2.5
	export SWAYSOCK=\$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1)
	swaymsg -t get_tree | jq -r '.. | objects | select(.app_id != null) | \"\(.app_id)\t\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)\"' 2>/dev/null"
