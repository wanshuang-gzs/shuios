#!/bin/bash
# 秒级开发闭环：只编译某个 GTK 应用 → 直接推进 VM 的可写分区运行。
#
# 不重打镜像（squashfs + 分区镜像要 5~8 分钟）。GTK 库本来就在镜像里，
# 二进制放在 /var/lib/shuios/dev/ 下就能跑，所以一轮迭代只要 ~20 秒。
#
# 用法（在 WSL 里）：
#   bash /mnt/d/shuios/tools/dev-deploy.sh shui-panel
#   bash /mnt/d/shuios/tools/dev-deploy.sh shui-store
#   bash /mnt/d/shuios/tools/dev-deploy.sh shui-browser
set -u

PKG=${1:-shui-panel}
# 包名和产出的二进制名不一定相同（shui-browser 实际是 shui-browser-bin，
# /usr/bin/shui-browser 只是设置环境变量的包装脚本）
case "$PKG" in
	shui-browser) BIN_NAME=shui-browser-bin ;;
	*) BIN_NAME=$PKG ;;
esac
BR=/root/shuios/buildroot
EXT=/root/shuios/br2-ext
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo ">>> 1/4 同步源码"
rsync -a /mnt/d/shuios/br2-ext/package/"$PKG"/ "$BR/../br2-ext/package/$PKG"/ 2>/dev/null || true

echo ">>> 2/4 编译 $PKG"
cd "$BR" || exit 1
if ! make -s BR2_EXTERNAL="$EXT" BR2_PRIMARY_SITE=file:///root/shuios-mirror \
	-j12 "$PKG-rebuild" > /tmp/dev-build.log 2>&1; then
	echo "!!! 编译失败："
	grep -E "error|错误" /tmp/dev-build.log | head -10
	tail -5 /tmp/dev-build.log
	exit 1
fi
BIN=$(ls -1 "$BR"/output/build/"$PKG"-*/"$BIN_NAME" 2>/dev/null | head -1)
[ -n "$BIN" ] || { echo "!!! 找不到 $PKG 二进制"; exit 1; }
echo "    二进制：$BIN ($(stat -c%s "$BIN") 字节)"

echo ">>> 3/4 停掉旧进程并推送到 VM 可写分区"
# 必须先杀进程：Linux 不允许覆盖正在执行的二进制（会报 Text file busy）
$SSH "pkill -x $BIN_NAME 2>/dev/null; sleep 0.5; true"
if ! cat "$BIN" | $SSH "mkdir -p /var/lib/shuios/dev && cat > /var/lib/shuios/dev/$BIN_NAME && chmod 0755 /var/lib/shuios/dev/$BIN_NAME"; then
	echo "!!! 推送失败（VM 在跑吗？）"
	exit 1
fi

echo ">>> 4/4 启动 $PKG"
case "$PKG" in
	shui-panel)
		$SSH "pkill -x shui-panel; sleep 0.4
			D=\$(ls /run/shuios/compositor 2>/dev/null | grep -m1 '^wayland-')
			XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=\$D \
				nohup /var/lib/shuios/dev/shui-panel >/tmp/dev-panel.log 2>&1 &
			sleep 1.5; pgrep -x shui-panel >/dev/null && echo '    ✓ 面板已重启' || { echo '    ! 面板没起来：'; head -5 /tmp/dev-panel.log; }"
		;;
	shui-store)
		$SSH "pkill -x shui-store; sleep 0.4
			D=\$(ls /run/shuios/compositor 2>/dev/null | grep -m1 '^wayland-')
			XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=\$D \
				nohup /var/lib/shuios/dev/shui-store >/tmp/dev-store.log 2>&1 &
			sleep 1.5; pgrep -x shui-store >/dev/null && echo '    ✓ 商店已重启' || { echo '    ! 商店没起来：'; head -5 /tmp/dev-store.log; }"
		;;
	shui-browser)
		# 用包装脚本启动：它会设置 XDG_* 目录和虚拟 GPU 的软件渲染变量，
		# 并优先使用 /var/lib/shuios/dev/shui-browser-bin。
		$SSH "pkill -x shui-browser-bin; sleep 0.4
			D=\$(ls /run/shuios/compositor 2>/dev/null | grep -m1 '^wayland-')
			XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=\$D \
				nohup /usr/bin/shui-browser >/tmp/dev-browser.log 2>&1 &
			sleep 3; pgrep -x shui-browser-bin >/dev/null && echo '    ✓ 浏览器已重启' || { echo '    ! 浏览器没起来：'; head -8 /tmp/dev-browser.log; }"
		;;
	*)
		echo "    （$PKG 没有重启规则，只推送了二进制）"
		;;
esac
echo ">>> 完成（未重打镜像）"
