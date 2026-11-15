#!/bin/bash
# 手动放一遍关机动画（10s），用于抓中间帧。桌面服务此时应当已停止。
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

$SSH 'systemctl is-active shuios-desktop; /usr/bin/shuios-splash --mode shutdown --duration 10; echo "splash rc=$?"'
