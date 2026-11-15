#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## wayland socket 在哪 ##########"
$SSH 'ls -l /run/shuios/*/wayland-0 2>/dev/null; echo ---; ps -o pid,args -C weston 2>/dev/null | head -3'

echo
echo "########## weston.ini ##########"
$SSH 'cat /etc/xdg/weston/weston.ini'

echo
echo "########## 有没有演示客户端 ##########"
$SSH 'ls /usr/bin/weston-* 2>/dev/null; echo ---; cat /sys/class/drm/card0-CONNECTOR_STATUS 2>/dev/null; cat /sys/class/drm/card0*/status 2>/dev/null | head -3'
