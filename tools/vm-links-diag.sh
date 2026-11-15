#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"
D=$($SSH 'ls /run/shuios/compositor 2>/dev/null | grep -m1 "^wayland-"')

echo "########## A. links -dump（非交互，验证抓取+渲染） ##########"
$SSH 'links -dump https://example.com 2>&1 | head -12'

echo
echo "########## B. 交互式：留在窗口里看报错 ##########"
$SSH "XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D \
	nohup /usr/bin/foot -e /bin/sh -c 'links https://example.com; echo \"[links 退出码=\$?]\"; sleep 120' >/tmp/links2.log 2>&1 &
	sleep 6; pgrep -af 'links' | grep -v bash | head -3"
