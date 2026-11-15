#!/bin/bash
# 启动 shuios 并截一张桌面图（用于验收）。
#
# 用 -vga std（bochs-drm）而不是 virtio-gpu：
#   * virtio-gpu + -display none 时 QEMU 的 screendump 抓不到显示内容（全白）
#   * bochs-drm 是标准 KMS 设备，Weston/mesa(llvmpipe) 直接可用，screendump 可靠
#
# 用法：bash tools/qemu-screenshot.sh [镜像] [等待秒数] [输出png]
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${1:-/mnt/d/shuios/shuios.img}"
WAIT="${2:-180}"
PNG="${3:-/mnt/d/shuios/shuios-desktop.png}"
SERIAL=/tmp/shuios-serial.log
MON=/tmp/shuios-mon.sock
PPM=/tmp/shuios-shot.ppm

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

rm -f "$MON" "$PPM" "$SERIAL"

echo ">>> 启动 QEMU（-vga std，等待 ${WAIT}s）"
qemu-system-x86_64 \
	-machine q35 -cpu max -m 4096 -smp 4 \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF" \
	-drive if=pflash,format=raw,file="$VARS" \
	-drive file="$IMG",format=raw,if=ide,index=0 \
	-netdev user,id=n0 -device e1000,netdev=n0 \
	-vga std \
	-display none \
	-nographic -serial file:"$SERIAL" \
	-monitor unix:"$MON",server,nowait &
QPID=$!

sleep "$WAIT"

echo ">>> screendump"
python3 - "$MON" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
time.sleep(0.3); s.recv(65536)
s.sendall(b"screendump /tmp/shuios-shot.ppm\n")
time.sleep(2)
try: print(s.recv(65536).decode(errors="replace"))
except Exception: pass
s.close()
PY

kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

if [ -f "$PPM" ]; then
	if command -v convert >/dev/null 2>&1; then
		convert "$PPM" "$PNG" && echo ">>> 截图: $PNG ($(stat -c%s "$PNG") 字节)"
	else
		cp "$PPM" "${PNG%.png}.ppm"; echo ">>> 无 convert，保留 PPM"
	fi
else
	echo "!!! 没有生成截图" >&2
fi

echo
echo ">>> 关键日志"
grep -aE 'Reached target|Started shuios|Started Weston|shuios-firstboot|A/B|login:' "$SERIAL" | tail -15 || true
