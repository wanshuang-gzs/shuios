#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## sway 日志里跟 waybar / dbus 有关的行 ##########"
$SSH 'grep -inE "waybar|dbus|autolaunch" /run/shuios/compositor/compositor.log 2>/dev/null | tail -12'

echo
echo "########## 桌面脚本里 D-Bus 那段实际是什么 ##########"
$SSH 'sed -n "20,50p" /usr/libexec/shuios/shuios-desktop'
