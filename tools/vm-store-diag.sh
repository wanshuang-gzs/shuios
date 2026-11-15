#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 二进制在不在 ##########"
$SSH 'ls -l /usr/bin/shui-store 2>&1'

echo
echo "########## 手动跑一次，看报错 ##########"
$SSH 'XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$(ls /run/shuios/compositor | grep -m1 "^wayland-") \
	timeout 8 /usr/bin/shui-store 2>&1 | head -20; echo "rc=$?"'

echo
echo "########## 桌面脚本有没有执行到商店 ##########"
$SSH 'grep -n "shui-store" /usr/libexec/shuios/shuios-desktop'
