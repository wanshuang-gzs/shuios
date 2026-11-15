#!/bin/bash
# 用正确的 socket 名启动动画客户端（这次先探测）
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

DISP=$($SSH 'ls /run/shuios/compositor/ | grep "^wayland-" | grep -v lock | head -1')
echo ">>> 使用 socket: $DISP"
$SSH "XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$DISP nohup /usr/bin/weston-simple-damage >/tmp/sd.log 2>&1 & sleep 2; pgrep -fc weston-simple-damage; tail -3 /tmp/sd.log"
