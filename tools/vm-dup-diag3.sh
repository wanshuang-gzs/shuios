#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## pgrep 在不在 ##########"
$SSH 'command -v pgrep || echo "!! 没有 pgrep"'

echo
echo "########## 重复进程的 cgroup（看是谁的子树） ##########"
$SSH 'for p in $(pgrep -x foot 2>/dev/null | head -3); do echo "pid=$p $(cat /proc/$p/comm 2>/dev/null) cgroup=$(cat /proc/$p/cgroup 2>/dev/null)"; done'
$SSH 'for p in $(pgrep -x shui-store 2>/dev/null | head -3); do echo "pid=$p cgroup=$(cat /proc/$p/cgroup 2>/dev/null)"; done'

echo
echo "########## 会话脚本/桌面脚本当前状态 ##########"
$SSH 'ps -o pid,ppid,etimes,args -e 2>/dev/null | grep -E "shuios-session|shuios-desktop|shuios-launch|sleep infinity" | grep -v grep'

echo
echo "########## sway 的 exec 记录（compositor.log 里找 spawn） ##########"
$SSH 'grep -icE "shuios-desktop|shuios-launch" /run/shuios/compositor/compositor.log 2>/dev/null'
