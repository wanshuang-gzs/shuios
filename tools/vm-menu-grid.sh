#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"
D=$($SSH 'ls /run/shuios/compositor 2>/dev/null | grep -m1 "^wayland-"')

echo "########## 打开开始菜单 ##########"
$SSH "XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D \
	nohup /var/lib/shuios/dev/shui-panel --menu >/tmp/menu3.log 2>&1 &
	sleep 2; pgrep -af 'shui-panel --menu' | grep -v bash | head -2; echo '--- 日志 ---'; head -6 /tmp/menu3.log"

echo
echo "########## 菜单窗口几何（应该是 420x480，贴任务栏上沿） ##########"
$SSH 'export SWAYSOCK=$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); \
	swaymsg -t get_tree | jq -r ".. | objects | select(.app_id != null) | \"\(.app_id)\t\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)\"" 2>/dev/null'

echo
echo "########## 菜单里的应用数（从 .desktop 读出来的） ##########"
$SSH 'ls /usr/share/applications/*.desktop 2>/dev/null | wc -l; ls /var/lib/shuios/pkg/share/applications/*.desktop 2>/dev/null | wc -l'
