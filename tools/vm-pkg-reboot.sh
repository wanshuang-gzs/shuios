#!/bin/bash
# 重启后验证 shui-pkg restore 是否自动重建挂载与包装脚本
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

$SSH 'sync; systemctl reboot' >/dev/null 2>&1
echo ">>> 已发出重启，等 100 秒"
sleep 100

echo
echo "########## 重启后：restore 是否生效 ##########"
$SSH 'export PATH=/var/lib/shuios/pkg/bin:$PATH; systemctl status shuios-pkg --no-pager -n 4 2>&1 | tail -6; echo ---; shui-pkg installed; echo ---; ls -l /var/lib/shuios/pkg/bin/; echo ---; curl --version 2>&1 | head -2'
