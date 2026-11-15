#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## sway 认为每个窗口用哪种装饰 ##########"
$SSH 'export SWAYSOCK=$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); \
	swaymsg -t get_tree | jq -r ".. | objects | select(.app_id != null) | \"\(.app_id)\tdecorations=\(.decorations // \"?\")\t\(.rect.width)x\(.rect.height)\"" 2>/dev/null'

echo
echo "########## foot 是否认 csd.preferred（非法值会报错退出） ##########"
$SSH 'foot -o csd.preferred=bogus -e /bin/true 2>&1 | head -3; echo "rc=$?"'

echo
echo "########## foot 帮助里 csd 相关 ##########"
$SSH 'strings /usr/bin/foot | grep -E "^csd\.|^\[csd\]" | sort -u | head -12'
