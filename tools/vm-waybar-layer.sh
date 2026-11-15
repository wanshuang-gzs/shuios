#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## sway 树里的 layer 表面 ##########"
$SSH 'export SWAYSOCK=$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1)
	swaymsg -t get_tree | jq -r ".. | objects | select(.type==\"layer_shell\" or .shell==\"layer_shell\") | \"\(.type) \(.shell) \(.name) \(.rect.width)x\(.rect.height) @ \(.rect.x),\(.rect.y)\"" 2>/dev/null | head -6
	echo "--- 所有节点类型统计 ---"
	swaymsg -t get_tree | jq -r "[.. | objects | .type? // empty] | group_by(.) | map(\"\(.[0]): \(length)\") | .[]" 2>/dev/null | head -8'

echo
echo "########## 桌面启动的 waybar 的日志（它输出到 sway 的 stdout） ##########"
$SSH 'grep -n "waybar" /run/shuios/compositor/compositor.log | tail -6'

echo
echo "########## 强制 waybar 重新加载配置 ##########"
$SSH 'pkill -SIGUSR2 -x waybar 2>/dev/null; sleep 2
	grep -c "" /run/shuios/compositor/compositor.log 2>/dev/null
	tail -4 /run/shuios/compositor/compositor.log'
