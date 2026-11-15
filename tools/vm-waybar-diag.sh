#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## waybar 在跑吗 ##########"
$SSH 'pgrep -af waybar | grep -v bash | head -3; echo "---"; ls -l /usr/bin/waybar'

echo
echo "########## 配置文件 ##########"
$SSH 'ls -l /etc/xdg/waybar/; echo ---; head -12 /etc/xdg/waybar/config 2>/dev/null'

echo
echo "########## 手动跑一次看报错 ##########"
D=$($SSH 'ls /run/shuios/compositor 2>/dev/null | grep -m1 "^wayland-"')
$SSH "XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D \
	nohup /usr/bin/waybar -l trace >/tmp/waybar.log 2>&1 &
	sleep 4; pgrep -x waybar >/dev/null && echo 'running' || echo 'died'; echo '--- 日志 ---'; head -25 /tmp/waybar.log"
