#!/bin/bash
# 验证任务栏"合并式按钮"：开窗口后按钮下应出现主色指示线
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"
D=$($SSH 'ls /run/shuios/compositor 2>/dev/null | grep -m1 "^wayland-"')

echo "########## 开一个终端窗口 ##########"
$SSH "XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D \
	nohup /usr/bin/foot -T 'shui 氵' -e /usr/bin/sleep 90 >/tmp/win1.log 2>&1 &
	sleep 3; /var/lib/shuios/dev/shui-ctl windows"

echo
echo "########## 面板看到的窗口列表（事件流是否跟上） ##########"
$SSH '/var/lib/shuios/dev/shui-ctl windows | wc -l; echo "--- 再开一个 ---"
	XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY='"$D"' nohup /usr/bin/foot -T "第二个" -e /usr/bin/sleep 90 >/tmp/win2.log 2>&1 &
	sleep 3; /var/lib/shuios/dev/shui-ctl windows'
