#!/bin/bash
# 手动跑 shuios-splash 并抓到它的 stderr / 退出码，确认是否 panic。
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo ">>> 目标 $GW"
$SSH 'systemctl stop shuios-desktop 2>/dev/null; pkill -x shuios-splash 2>/dev/null; sleep 1; /usr/bin/shuios-splash --mode boot --duration 2; echo "退出码=$?"'

echo
echo ">>> 版本/路径"
$SSH 'ls -l /usr/bin/shuios-splash; /usr/bin/shuios-splash --help'
