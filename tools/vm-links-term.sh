#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"
D=$($SSH 'ls /run/shuios/compositor 2>/dev/null | grep -m1 "^wayland-"')

echo "########## terminfo 有哪些 ##########"
$SSH 'ls /usr/share/terminfo/x/ 2>/dev/null | head -6; echo ---; ls /usr/share/terminfo/f/ 2>/dev/null | head -3'

echo
echo "########## 用 TERM=xterm-256color 在 foot 里开 links ##########"
$SSH "XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D \
	nohup /usr/bin/foot -T '浏览器 · links' -e /usr/bin/env TERM=xterm-256color \
	/usr/bin/links https://example.com >/tmp/links3.log 2>&1 &
	sleep 6; echo '--- 存活进程 ---'; pgrep -af 'links https' | grep -v bash | head -2"
echo
echo "########## sway 窗口列表 ##########"
$SSH "export SWAYSOCK=\$(ls /run/shuios/compositor/sway-ipc.*.sock | head -1); /var/lib/shuios/dev/shui-ctl windows"
