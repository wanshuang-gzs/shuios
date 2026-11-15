#!/bin/bash
# 重启整个桌面会话（等价于开机时的路径），验证 waybar 会自己起来
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo ">>> 先杀掉所有 waybar（清场）"
$SSH 'pkill -x waybar; sleep 1; pgrep -c -x waybar || echo 0'

echo ">>> 重启桌面服务"
$SSH 'systemctl restart shuios-desktop; sleep 14'

echo ">>> 现在有哪些关键进程"
$SSH 'for p in sway waybar dbus-daemon shui-panel; do printf "  %-13s %s\n" "$p" "$(pgrep -x $p | tr "\n" " ")"; done'

echo ">>> waybar 是否读到了我们自己的配置"
$SSH 'grep -inE "waybar|Bar configured" /run/shuios/compositor/compositor.log 2>/dev/null | tail -5'
