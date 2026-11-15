#!/bin/bash
# 同步触发桌面停止（前台 SSH，保证命令真的送达）。调用方应把它放在后台作业里，
# 这样 WSL 会话不会在 SSH 完成前退出。
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo ">>> stop $GW"
$SSH 'systemctl stop shuios-desktop.service; echo "stop rc=$?"; systemctl is-active shuios-desktop'
echo ">>> done"
