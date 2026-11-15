#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 进程父子链 ##########"
$SSH 'ps -o pid,ppid,args -e 2>/dev/null | grep -E "foot|shui-store|shui-desktop|shuios-session" | grep -v grep | head -16'

echo
echo "########## 商店重试日志 ##########"
$SSH 'head -20 /tmp/shui-store.log 2>/dev/null || echo "(无)"'

echo
echo "########## 谁在反复启动东西：/proc 里最近启动的进程 ##########"
$SSH 'ps -o pid,etimes,args -e 2>/dev/null | awk "\$2 < 120" | sort -k2 -n | head -20'
