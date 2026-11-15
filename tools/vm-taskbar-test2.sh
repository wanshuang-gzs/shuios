#!/bin/bash
# 用镜像自带的 shui-ctl 验证：窗口列表 + 任务栏运行指示
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"
D=$($SSH 'ls /run/shuios/compositor 2>/dev/null | grep -m1 "^wayland-"')

echo "########## 1. 镜像里的 shui-ctl windows ##########"
$SSH '/usr/bin/shui-ctl windows; echo "退出码=$?"'

echo
echo "########## 2. 开一个终端窗口 ##########"
$SSH "XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D \
	nohup /usr/bin/foot -T 'shui 氵' -e /usr/bin/sleep 120 >/tmp/w1.log 2>&1 &
	sleep 4; /usr/bin/shui-ctl windows; echo '--- 面板进程 ---'; pgrep -af shui-panel"

echo
echo "########## 3. 再开一个（验证事件流） ##########"
$SSH "XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D \
	nohup /usr/bin/foot -T '第二个窗口' -e /usr/bin/sleep 120 >/tmp/w2.log 2>&1 &
	sleep 4; /usr/bin/shui-ctl windows"
