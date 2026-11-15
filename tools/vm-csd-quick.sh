#!/bin/bash
# 用可写分区里的临时 foot 配置验证 CSD（避免为此重建镜像）
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 0. 在 VM 里取 wayland socket 名 ##########"
D=$($SSH 'ls /run/shuios/compositor 2>/dev/null | grep -m1 "^wayland-"')
echo "display=$D"

echo
echo "########## 1. 写一份带 csd 的临时 foot 配置 ##########"
$SSH 'mkdir -p /var/lib/shuios/footcfg/foot && cat > /var/lib/shuios/footcfg/foot/foot.ini <<EOF
[main]
font=DejaVu Sans Mono:size=11
pad=14x12
[csd]
preferred=client
size=28
border-width=1
border-color=2a323d
double-click-to-maximize=yes
EOF
echo written; head -12 /var/lib/shuios/footcfg/foot/foot.ini'

echo
echo "########## 2. 启动终端（带 CSD） ##########"
$SSH "XDG_CONFIG_HOME=/var/lib/shuios/footcfg XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D \
	nohup /usr/bin/foot -T '终端' -e /usr/bin/sleep 60 >/tmp/foot3.log 2>&1 &
	sleep 3; pgrep -af 'foot -T' | head -2; echo '--- log ---'; head -5 /tmp/foot3.log"

echo
echo "########## 3. 启动开始菜单（带正确 display） ##########"
$SSH "XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D \
	nohup /usr/bin/shui-panel --menu >/tmp/menu2.log 2>&1 &
	sleep 2; pgrep -af 'shui-panel --menu' | head -2"

echo
echo "########## 4. sway 里的窗口 ##########"
$SSH 'export SWAYSOCK=$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); \
	swaymsg -t get_tree | jq -r ".. | objects | select(.app_id != null) | \"\(.app_id)\t\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)\"" 2>/dev/null'
