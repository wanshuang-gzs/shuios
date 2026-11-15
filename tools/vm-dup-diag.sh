#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 实际进程数 ##########"
$SSH 'for p in foot shui-store shui-panel shui mc; do printf "%-11s %s\n" "$p" "$(pgrep -c -x $p 2>/dev/null || echo 0)"; done'

echo
echo "########## foot 进程的启动时间与命令行 ##########"
$SSH 'ps -o pid,etimes,args -e 2>/dev/null | grep -E "foot|shui-store" | grep -v grep | head -14'

echo
echo "########## sway 日志里的 reload / exec ##########"
$SSH 'grep -iE "reload|config|exec" /run/shuios/compositor/compositor.log 2>/dev/null | tail -12'
