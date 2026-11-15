#!/usr/bin/env bash
# 用 QEMU 启动 shuios 镜像。
#
# 模式（环境变量 GRAPHICS）：
#   gtk   —— 打开本地窗口看桌面（需要 X11/Wayland 会话）
#   vnc   —— 不开窗口，暴露 VNC（:1），用 VNC 客户端看
#   none  —— 纯串口（默认；适合 CI / 截图验证）
#
# 用法：
#   tools/qemu-run.sh [镜像路径] [额外 QEMU 参数...]
#   GRAPHICS=gtk tools/qemu-run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${1:-$ROOT/output/images/shuios.img}"
shift || true

if [ ! -f "$IMG" ]; then
	echo "找不到镜像: $IMG" >&2
	exit 1
fi

find_ovmf() {
	for c in /usr/share/OVMF/OVMF_CODE_4M.fd \
	         /usr/share/OVMF/OVMF_CODE.fd \
	         /usr/share/edk2/ovmf/OVMF_CODE.fd \
	         /usr/share/edk2/x64/OVMF_CODE.fd \
	         /usr/share/qemu/OVMF_CODE.fd; do
		[ -f "$c" ] && { echo "$c"; return 0; }
	done
	return 1
}

OVMF_CODE="${OVMF_CODE:-$(find_ovmf || true)}"
if [ -z "${OVMF_CODE}" ]; then
	echo "找不到 OVMF 固件（apt install ovmf）" >&2
	exit 1
fi
case "$OVMF_CODE" in
	*OVMF_CODE_4M.fd) VARS_SRC="${OVMF_CODE%_CODE_4M.fd}_VARS_4M.fd" ;;
	*)                VARS_SRC="${OVMF_CODE%_CODE.fd}_VARS.fd" ;;
esac
VARS="$(mktemp /tmp/shuios-vars.XXXXXX)"
[ -f "$VARS_SRC" ] && cp -f "$VARS_SRC" "$VARS"

MEM="${MEM:-4096}"
CPUS="${CPUS:-4}"
GRAPHICS="${GRAPHICS:-none}"

case "$GRAPHICS" in
	gtk)  DISPLAY_OPTS=(-display gtk) ;;
	vnc)  DISPLAY_OPTS=(-display none -vnc 0.0.0.0:1) ;;
	*)    DISPLAY_OPTS=(-display none) ;;
esac

echo ">>> shuios: $IMG"
echo ">>> 内存 ${MEM}M / ${CPUS} 核 / 显示模式 $GRAPHICS"

exec qemu-system-x86_64 \
	-machine q35,accel=kvm:tcg \
	-cpu max \
	-m "$MEM" -smp "$CPUS" \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
	-drive if=pflash,format=raw,file="$VARS" \
	-drive file="$IMG",format=raw,if=ide,index=0 \
	-netdev user,id=n0 -device e1000,netdev=n0 \
	-device virtio-gpu-pci \
	-vga none \
	"${DISPLAY_OPTS[@]}" \
	-nographic \
	-monitor unix:/tmp/shuios-monitor.sock,server,nowait \
	"$@"
