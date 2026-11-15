#!/bin/bash
# 验证任务栏点击逻辑依赖的三条 swaymsg 命令，以及工作区名是否为 __i3_scratch
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"
CTL=/var/lib/shuios/dev/shui-ctl

show() { $SSH "export SWAYSOCK=\$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); $CTL windows"; }

echo "########## 初始状态 ##########"
show

ID=$($SSH "export SWAYSOCK=\$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); $CTL windows | grep -v shui-panel | head -1 | cut -f4")
echo "取一个窗口 con_id=$ID"

echo
echo "########## 1) 聚焦 ##########"
$SSH "export SWAYSOCK=\$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); swaymsg '[con_id=$ID] focus' >/dev/null; $CTL windows | grep -v shui-panel"

echo
echo "########## 2) 最小化（move scratchpad） ##########"
$SSH "export SWAYSOCK=\$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); swaymsg '[con_id=$ID] move scratchpad' >/dev/null; $CTL windows | grep -v shui-panel"

echo
echo "########## 3) 还原（scratchpad show） ##########"
$SSH "export SWAYSOCK=\$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); swaymsg '[con_id=$ID] scratchpad show' >/dev/null; $CTL windows | grep -v shui-panel"
