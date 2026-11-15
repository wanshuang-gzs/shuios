#!/bin/bash
# 重启后检查：shui-pkg restore 是否自动把已装包重新挂好
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## shuios-pkg 单元 ##########"
$SSH 'systemctl is-active shuios-pkg; systemctl show -p ExecMainStatus shuios-pkg; journalctl -u shuios-pkg -n 5 --no-pager | tail -5'
echo
echo "########## 已装清单与挂载 ##########"
$SSH 'export PATH=/var/lib/shuios/pkg/bin:$PATH; shui-pkg installed; echo ---; grep "pkg/mnt" /proc/mounts; echo ---; curl --version 2>&1 | head -2'
echo
echo "########## 桌面进程 ##########"
$SSH 'ps -o pid,comm -C weston,shui-store,foot 2>/dev/null | head -8'
