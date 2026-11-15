#!/bin/bash
# 编译 shui-browser 并热部署到运行中的 shuios VM（默认 192.168.172.131）
# 用法：bash tools/dev-deploy-browser.sh [VM_IP] [启动URL]
set -u
H=${1:-192.168.172.131}
URL=${2:-}
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@$H"

echo ">>> sync source"
rsync -a /mnt/d/shuios/br2-ext/package/shui-browser/src/ /root/shuios/br2-ext/package/shui-browser/src/ || exit 1
rsync -a /mnt/d/shuios/br2-ext/package/shui-browser/src/shui-browser.c /root/shuios/buildroot/output/build/shui-browser-0.1.0/shui-browser.c || exit 1

echo ">>> build"
cd /root/shuios/buildroot || exit 1
if ! make -s BR2_EXTERNAL=/root/shuios/br2-ext BR2_PRIMARY_SITE=file:///root/shuios-mirror \
	-j8 shui-browser-rebuild > /tmp/dev-build.log 2>&1; then
	echo "BUILD FAIL"; grep -E 'error|错误' /tmp/dev-build.log | head; exit 1
fi
BIN=/root/shuios/buildroot/output/build/shui-browser-0.1.0/shui-browser-bin
ls -l "$BIN" || exit 1

echo ">>> push"
$SSH "pkill -x shui-browser-bi 2>/dev/null; sleep 0.5; true"
cat "$BIN" | $SSH "mkdir -p /var/lib/shuios/dev && cat > /var/lib/shuios/dev/shui-browser-bin && chmod 0755 /var/lib/shuios/dev/shui-browser-bin" || exit 1

echo ">>> launch"
$SSH "D=\$(ls /run/shuios/compositor | grep -m1 '^wayland-')
XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=\$D \
	nohup /usr/bin/shui-browser $URL >/tmp/dev-browser.log 2>&1 &
sleep 2
ps -eo pid,comm | grep '^ *[0-9]* shui-browser-b' || echo none"
