#!/bin/bash
# 把开始菜单挪到正确位置（运行中的 sway 配置还是镜像里的旧版），然后看几何
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

$SSH 'export SWAYSOCK=$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1)
	swaymsg "[app_id=\"shui-panel-menu\"] move position 4 258, resize set 420 480" >/dev/null
	sleep 1
	swaymsg -t get_tree | jq -r ".. | objects | select(.app_id != null) | \"\(.app_id)\t\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)\"" 2>/dev/null'
