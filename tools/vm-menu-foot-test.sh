#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"
D=$(ls /run/shuios/compositor | grep -m1 '^wayland-')

echo "########## 1. 启动开始菜单（独立进程） ##########"
$SSH "XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D nohup /usr/bin/shui-panel --menu >/tmp/menu.log 2>&1 &
	sleep 2; pgrep -af 'shui-panel --menu' | head -2"

echo
echo "########## 2. 启动一个终端，看它有没有标题栏 ##########"
$SSH "XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D nohup /usr/bin/foot -T '终端标题栏测试' -e /usr/bin/sleep 40 >/tmp/foot2.log 2>&1 &
	sleep 3; pgrep -af 'foot -T' | head -2"

echo
echo "########## 3. sway 里的窗口（看 app_id 与尺寸） ##########"
$SSH 'export SWAYSOCK=$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); \
	swaymsg -t get_tree | jq -r ".. | objects | select(.app_id != null) | \"\(.app_id)\t\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)\"" 2>/dev/null'

echo
echo "########## 4. foot 日志里有没有 csd 报错 ##########"
$SSH 'head -6 /tmp/foot2.log 2>/dev/null'
