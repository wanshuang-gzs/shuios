#!/bin/bash
# 在 Windows 桌面上开一个 QEMU 窗口，直接看 shuios 桌面（WSLg 提供图形）。
#
# 鼠标：用 -device usb-tablet（绝对定位）。默认的 PS/2 鼠标是相对定位，
# 在没有鼠标捕获/释放切换的情况下会"漂"，加平板设备后指针位置与宿主一致。
#
# 用法：wsl -d shui-build -u root -- bash /mnt/d/shuios/tools/qemu-window.sh [镜像]
set -u

IMG="${1:-/root/test.img}"
SERIAL=/tmp/shuios-window-serial.log
QOUT=/tmp/qemu-window.out

if [ ! -f "$IMG" ]; then
	echo "找不到镜像: $IMG" >&2
	exit 1
fi

pkill -9 -f "qemu-system-x86_64" 2>/dev/null || true
sleep 1
rm -f "$SERIAL" "$QOUT"

OVMF=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.fd; do
	[ -f "$c" ] && OVMF="$c" && break
done
[ -z "$OVMF" ] && { echo "缺少 OVMF" >&2; exit 1; }
case "$OVMF" in
	*OVMF_CODE_4M.fd) VARS_SRC="${OVMF%_CODE_4M.fd}_VARS_4M.fd" ;;
	*)                VARS_SRC="${OVMF%_CODE.fd}_VARS.fd" ;;
esac
VARS=$(mktemp /tmp/shuios-vars.XXXXXX)
[ -f "$VARS_SRC" ] && cp -f "$VARS_SRC" "$VARS"

setsid nohup qemu-system-x86_64 \
	-machine q35 -cpu max -m 4096 -smp 4 \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF" \
	-drive if=pflash,format=raw,file="$VARS" \
	-drive file="$IMG",format=raw,if=ide,index=0 \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:10022-:22 \
	-device e1000,netdev=n0 \
	-vga std \
	-device qemu-xhci,id=xhci
	-device usb-tablet,bus=xhci.0 \
	-display gtk,zoom-to-fit=on \
	-name "shuios 0.1 (氵系统)" \
	-serial file:"$SERIAL" \
	> "$QOUT" 2>&1 < /dev/null &

sleep 4
if pgrep -f "qemu-system-x86_64" > /dev/null 2>&1; then
	echo "已启动 QEMU 窗口（USB 平板鼠标，绝对定位）"
	echo "  提示：按 Ctrl+Alt+G 释放/捕获鼠标"
else
	echo "启动失败："
	cat "$QOUT"
	exit 1
fi
