#!/bin/bash
# 在运行的 shuios 虚拟机里手动启动 sway，捕获它的真实报错。
set -u
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@127.0.0.1"

echo "===== 停掉自动重启的桌面服务 ====="
$SSH 'systemctl stop shuios-desktop; echo stopped'

echo
echo "===== 手动运行 sway（12 秒后自动结束）====="
$SSH 'mkdir -p /tmp/xdg && chmod 700 /tmp/xdg; XDG_RUNTIME_DIR=/tmp/xdg XDG_SESSION_TYPE=wayland WLR_RENDERER=gles2 timeout 12 sway --unsupported-gpu --config /etc/shuios/sway-config 2>&1 | head -50; echo "[退出码 $?]"'

echo
echo "===== 相关库/文件检查 ====="
$SSH 'ls -l /usr/bin/sway /usr/bin/swaybar /etc/shuios/sway-config 2>&1; echo ---; ls /usr/lib/libwlroots* 2>&1 | head -3; echo ---; ls /usr/lib/dri/ 2>/dev/null | head -6'
