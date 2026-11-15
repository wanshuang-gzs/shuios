#!/bin/bash
# 检查新单元是否进镜像，并触发桌面停止以观察关机动画。
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo ">>> 单元内容"
$SSH 'systemctl cat shuios-desktop.service | grep -E "ExecStopPost|ExecStart=" ; echo ---; systemctl is-active shuios-desktop; echo ---; systemctl cat shuios-splash-shutdown.service | grep ExecStart'
