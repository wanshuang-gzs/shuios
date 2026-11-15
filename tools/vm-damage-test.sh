#!/bin/bash
# 在桌面会话里跑 weston-simple-damage（一个只重绘脏区的动画方块）。
# 如果屏幕"每帧都留着"，方块会越叠越多；正常的话任何时刻只有一个方块。
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

$SSH 'ls /run/shuios/compositor/ | head; echo ---; ls -l /run/shuios/compositor/wayland-* 2>/dev/null'
echo
echo ">>> 启动动画客户端"
$SSH 'XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=wayland-0 nohup /usr/bin/weston-simple-damage >/tmp/sd.log 2>&1 & sleep 2; pgrep -c weston-simple-damage; tail -3 /tmp/sd.log'
