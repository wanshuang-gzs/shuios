#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 面板二进制 ##########"
$SSH 'ls -l /usr/bin/shui-panel 2>&1'

echo
echo "########## 手动跑（看报错） ##########"
$SSH 'D=$(ls /run/shuios/compositor | grep -m1 "^wayland-"); \
	XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D nohup /usr/bin/shui-panel >/tmp/panel.log 2>&1 & \
	sleep 3; pgrep -af shui-panel | head -2; echo "--- log ---"; head -12 /tmp/panel.log'
