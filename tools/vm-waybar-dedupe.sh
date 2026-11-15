#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## waybar 实例数 ##########"
$SSH 'pgrep -c -x waybar; echo "--- 命令行 ---"; ps -o pid,args -C waybar 2>/dev/null | head -4'

echo
echo "########## 若有重复，只保留一个 ##########"
$SSH 'n=$(pgrep -c -x waybar); if [ "$n" -gt 1 ]; then for p in $(pgrep -x waybar | tail -n +2); do kill "$p"; done; echo "已收敛到 1 个"; else echo "本来就 $n 个"; fi; sleep 1; pgrep -c -x waybar'
