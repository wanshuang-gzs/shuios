#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## compositor.log 里跟商店有关的 ##########"
$SSH 'grep -iE "store|gtk|glib|css|critical|abort|signal" /run/shuios/compositor/compositor.log 2>/dev/null | tail -15'

echo
echo "########## 现在有几个窗口 ##########"
$SSH 'export SWAYSOCK=$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); swaymsg -t get_tree | jq -c ".. | objects | select(.name != null and .app_id != null) | {app: .app_id, name: (.name|.[0:20]), x: .rect.x, y: .rect.y, w: .rect.width, h: .rect.height}" 2>/dev/null'
