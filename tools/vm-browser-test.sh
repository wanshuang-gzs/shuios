#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 1. links 装上了吗 ##########"
$SSH 'command -v links && links -version 2>&1 | head -2'

echo
echo "########## 2. 智能体工具 web.fetch ##########"
$SSH '/usr/bin/shui-ctl call web.fetch "{\"url\":\"https://example.com\"}" 2>&1 | head -12'

echo
echo "########## 3. 工具列表里有它吗 ##########"
$SSH '/usr/bin/shui-ctl tools 2>&1 | grep -E "web.fetch|pkg.list"'

echo
echo "########## 4. 在终端里真的开一个 links 窗口 ##########"
D=$($SSH 'ls /run/shuios/compositor 2>/dev/null | grep -m1 "^wayland-"')
$SSH "XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D \
	nohup /usr/bin/foot -e /usr/bin/links https://example.com >/tmp/links.log 2>&1 &
	sleep 6; pgrep -af links | head -2; echo '--- log ---'; head -4 /tmp/links.log"
