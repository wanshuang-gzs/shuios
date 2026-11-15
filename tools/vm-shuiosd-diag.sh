#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## shuiosd 状态 ##########"
$SSH 'systemctl status shuiosd --no-pager -l 2>&1 | head -14'

echo
echo "########## shuiosd 日志 ##########"
$SSH 'journalctl -u shuiosd --no-pager -n 20 2>&1 | tail -14'

echo
echo "########## socket ##########"
$SSH 'ls -l /run/shuios/ 2>&1; echo ---; ps -o pid,comm -C shuiosd 2>/dev/null'
