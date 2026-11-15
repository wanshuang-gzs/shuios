#!/bin/bash
# 启动桌面，等它稳定，为真实关机测试做准备。
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

$SSH 'systemctl start shuios-desktop.service; sleep 6; systemctl is-active shuios-desktop; pgrep -c weston'
