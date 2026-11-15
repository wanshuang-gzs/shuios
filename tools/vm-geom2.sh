#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 窗口几何（sway 自己报的） ##########"
$SSH 'export SWAYSOCK=$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); swaymsg -t get_tree | jq -c ".. | objects | select(.name != null and .rect != null) | {name: .name, app: .app_id, x: .rect.x, y: .rect.y, w: .rect.width, h: .rect.height, floating: (.type == \"floating_con\")}" 2>/dev/null | head -8'

echo
echo "########## 窗口数量 ##########"
$SSH 'export SWAYSOCK=$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); swaymsg -t get_tree | jq "[.. | objects | select(.name != null and .app_id != null)] | length" 2>/dev/null'

echo
echo "########## 字号/字体检查：bar 与 foot 的配置 ##########"
$SSH 'grep -E "font|height" /etc/shuios/sway-config | head -5; echo ---; grep -E "^font|^pad" /etc/xdg/foot/foot.ini'
