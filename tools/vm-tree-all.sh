#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 全部应用窗口 ##########"
$SSH 'export SWAYSOCK=$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); \
	swaymsg -t get_tree | jq -r ".. | objects | select(.app_id != null) | \"\(.app_id)\t\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)\"" 2>/dev/null'

echo
echo "########## 面板进程 ##########"
$SSH 'pgrep -af shui-panel | grep -v bash | head -3'
