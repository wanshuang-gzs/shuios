#!/bin/bash
# 在虚拟机里手动跑 sway 并抓取真实报错（镜像里没有 timeout，用后台+kill 代替）。
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "===== 释放会话并重启 seatd ====="
$SSH 'systemctl stop shuios-desktop; systemctl restart seatd; sleep 1; echo ok'

echo
echo "===== 手动启动 sway（12 秒后杀掉）====="
$SSH 'mkdir -p /tmp/xdg; chmod 700 /tmp/xdg; (XDG_RUNTIME_DIR=/tmp/xdg WLR_RENDERER=pixman /usr/bin/sway --unsupported-gpu --config /etc/shuios/sway-config >/tmp/sway.log 2>&1 &); sleep 12; pkill -9 -f "/usr/bin/sway"; echo "--- sway.log ---"; head -45 /tmp/sway.log'

echo
echo "===== seatd 日志 ====="
$SSH 'journalctl -u seatd --no-pager -n 10 | tail -10'
