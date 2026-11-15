#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo ">>> 状态"
$SSH 'systemctl is-active shuios-desktop; echo "---"; ps -o pid,comm -C weston,sway,shuios-splash,foot 2>/dev/null | head; echo "---"; ls -la /run/shuios/ | head -12'
echo
echo ">>> 日志"
$SSH 'journalctl -u shuios-desktop --no-pager -n 20 2>&1 | tail -16'
