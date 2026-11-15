#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 字体 ##########"
$SSH 'ls /usr/share/fonts/ 2>/dev/null; echo ---; find /usr/share/fonts -name "*.tt*" -o -name "*.otf" 2>/dev/null | head -10; echo ---; which fc-list && fc-list 2>/dev/null | head -6'

echo
echo "########## 壁纸 / 工具 ##########"
$SSH 'for b in swaybg swaybg-config swaybar foot weston-screenshooter; do printf "%s: " "$b"; command -v "$b" || echo "-"; done'

echo
echo "########## 桌面项（有 .desktop 的） ##########"
$SSH 'ls /usr/share/applications/ 2>/dev/null'
