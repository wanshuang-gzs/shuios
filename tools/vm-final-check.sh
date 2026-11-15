#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 进程 ##########"
$SSH 'ps -o pid,ppid,comm -C sway,swaybar,foot,shui-store,shuiosd 2>/dev/null'
echo
echo "########## /run/shuios ##########"
$SSH 'ls -l /run/shuios/; echo ---; ls -l /run/shuios/compositor/ | head -5'
echo
echo "########## 状态栏 ##########"
$SSH '/usr/bin/shui-ctl bar'
