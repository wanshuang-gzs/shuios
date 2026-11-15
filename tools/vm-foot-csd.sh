#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## foot.ini(5) 里的 [csd] 段 ##########"
$SSH 'zcat /usr/share/man/man5/foot.ini.5.gz 2>/dev/null | sed -n "/^\[csd\]/,/^\[/p" | head -60'

echo
echo "########## 我们的 foot.ini 有没有 csd ##########"
$SSH 'grep -n "csd" /etc/xdg/foot/foot.ini || echo "(没有 csd 段)"'

echo
echo "########## 试着用命令行覆盖启动，看有没有标题栏 ##########"
$SSH 'D=$(ls /run/shuios/compositor | grep -m1 "^wayland-"); \
	XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D nohup /usr/bin/foot \
	  -o csd.preferred=client -o csd.size=26 -T "csd 测试" -e /usr/bin/sleep 30 >/tmp/foot-csd.log 2>&1 & \
	sleep 3; echo "--- 日志 ---"; cat /tmp/foot-csd.log | head -8'
