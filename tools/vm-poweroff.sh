#!/bin/bash
# 真实关机：触发 poweroff，交给调用方抓图验证关机动画。
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo ">>> poweroff $GW"
$SSH 'sync; systemctl poweroff' || echo "ssh 断开（关机中，正常）"
echo ">>> issued"
