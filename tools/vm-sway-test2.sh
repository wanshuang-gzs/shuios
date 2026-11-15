#!/bin/bash
# 现在 weston.service 已被 mask，测试 sway 能否拿到 DRM master。
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## weston 有哪些渲染器选项 ##########"
$SSH 'weston --help 2>&1 | grep -iE "renderer|use-pixman" | head -5'

echo
echo "########## 切到 sway ##########"
$SSH 'mkdir -p /run/systemd/system/shuios-desktop.service.d
cat > /run/systemd/system/shuios-desktop.service.d/99-sway.conf <<EOF
[Service]
Environment=SHUIOS_COMPOSITOR=sway
EOF
systemctl daemon-reload
systemctl restart shuios-desktop
sleep 12
echo "--- 进程 ---"
ps -o pid,comm -C sway,weston,foot,shui-store 2>/dev/null | head -8
echo "--- 合成器日志尾部 ---"
tail -20 /run/shuios/compositor/compositor.log 2>/dev/null
echo "--- DRM master 报错? ---"
grep -c "drm master" /run/shuios/compositor/compositor.log 2>/dev/null' 