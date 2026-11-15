#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

$SSH 'D=$(ls /run/shuios/compositor | grep -m1 "^wayland-"); echo "display=$D";
	XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D nohup /usr/bin/shui-store >/tmp/store.log 2>&1 &
	sleep 3;
	echo "--- 进程 ---"; pgrep -af shui-store | head -3;
	echo "--- 日志 ---"; cat /tmp/store.log | head -20'
