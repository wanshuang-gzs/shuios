#!/bin/sh
# 检查桌面组件是否都装进了目标 rootfs。
set -u
T=/root/shuios/buildroot/output/target

echo "===== 可执行文件 ====="
for b in sway swaybar swaybg swayidle swaylock foot mc dmenu dmenu_path shui shui-ctl; do
	if [ -x "$T/usr/bin/$b" ]; then
		echo "OK    $b"
	else
		echo "MISS  $b"
	fi
done

echo
echo "===== 配置 ====="
ls -l "$T/etc/sway/config" 2>/dev/null || echo "MISS /etc/sway/config"
ls -l "$T/usr/lib/systemd/system/shuios-desktop.service" 2>/dev/null || echo "MISS shuios-desktop.service"

echo
echo "===== 开机启用 ====="
ls -1 "$T/etc/systemd/system/multi-user.target.wants/" 2>/dev/null
