#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## shui-ctl bar（swaybar 的状态输入） ##########"
$SSH '/usr/bin/shui-ctl bar 2>&1 | head -2'

echo
echo "########## sway 版本与输出 ##########"
$SSH 'XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=wayland-1 swaymsg -t get_version 2>&1; XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=wayland-1 swaymsg -t get_outputs 2>&1 | head -12'

echo
echo "########## 当前是哪个合成器 ##########"
$SSH 'ps -o pid,comm -C sway,weston,swaybar 2>/dev/null'
