#!/bin/bash
# 停桌面 → 手动跑 shuios-splash（用于验证开机动画能画出画面）。
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo ">>> 目标 $GW"
$SSH 'systemctl stop shuios-desktop 2>/dev/null; sleep 1; (/usr/bin/shuios-splash --mode boot --duration 30 > /tmp/splash.log 2>&1 &); sleep 2; echo "--- splash.log ---"; cat /tmp/splash.log; echo "--- 进程 ---"; ps -eo comm | grep -c shuios-splash'
