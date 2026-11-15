#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 进程树 ##########"
$SSH 'ps -o pid,ppid,etime,args -e 2>/dev/null | grep -E "weston|shuios|foot|store" | grep -v grep'

echo
echo "########## shuios-desktop 单元 ##########"
$SSH 'systemctl show -p MainPID -p NRestarts -p ActiveEnterTimestamp shuios-desktop; systemctl status shuios-desktop --no-pager -n 6 2>&1 | tail -8'

echo
echo "########## 两个日志的尾部 ##########"
echo "--- /run/shuios/weston/compositor.log ---"
$SSH 'tail -12 /run/shuios/weston/compositor.log 2>/dev/null'
echo "--- /run/shuios/compositor/compositor.log ---"
$SSH 'tail -12 /run/shuios/compositor/compositor.log 2>/dev/null'
