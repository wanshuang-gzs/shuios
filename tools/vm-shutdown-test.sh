#!/bin/bash
# 触发关机，用于验证关机动画（调用方随后立刻截图）。
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo ">>> 目标 $GW"
$SSH 'systemctl start shuios-splash-shutdown.service 2>&1 | head -3; sleep 0.5; echo triggered'
