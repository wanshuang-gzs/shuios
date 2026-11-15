#!/usr/bin/env bash
# 在 WSL 里用 QEMU 冒烟启动 shuios 镜像，并**截图**验收桌面。
#
# 用法：tools/smoke-test.sh [镜像路径] [等待秒数]
# 产出：
#   qemu-boot.log            串口日志
#   shuios-desktop.png       桌面截图（用 QEMU monitor 的 screendump 抓）
#
# 退出码：0 = 关键标志齐全；1 = 失败
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${1:-$ROOT/shuios.img}"
WAIT="${2:-180}"
OUT="${OUT:-$ROOT/qemu-boot.log}"
SHOT="${SHOT:-$ROOT/shuios-desktop.png}"
MON="/tmp/shuios-monitor.sock"

if [ ! -f "$IMG" ]; then
	echo "找不到镜像: $IMG" >&2
	exit 1
fi

OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.fd; do
	[ -f "$c" ] && OVMF_CODE="$c" && break
done
[ -z "$OVMF_CODE" ] && { echo "缺少 OVMF（apt install ovmf）" >&2; exit 1; }

case "$OVMF_CODE" in
	*OVMF_CODE_4M.fd) VARS_SRC="${OVMF_CODE%_CODE_4M.fd}_VARS_4M.fd" ;;
	*)                VARS_SRC="${OVMF_CODE%_CODE.fd}_VARS.fd" ;;
esac
VARS="$(mktemp /tmp/shuios-vars.XXXXXX)"
[ -f "$VARS_SRC" ] && cp -f "$VARS_SRC" "$VARS"

rm -f "$MON" "$SHOT"

echo ">>> 启动 QEMU（等待 ${WAIT}s 让桌面起来）"
qemu-system-x86_64 \
	-machine q35 \
	-cpu max \
	-m 4096 -smp 4 \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
	-drive if=pflash,format=raw,file="$VARS" \
	-drive file="$IMG",format=raw,if=ide,index=0 \
	-netdev user,id=n0 -device e1000,netdev=n0 \
	-device virtio-gpu-pci -vga none \
	-display none \
	-nographic -serial file:"$OUT" \
	-monitor unix:"$MON",server,nowait &
QPID=$!

sleep "$WAIT"

echo ">>> 抓取桌面截图"
if [ -S "$MON" ]; then
	# QEMU monitor 是文本协议；用 python 发一条 screendump
	python3 - "$MON" <<'PY' || echo "（截图失败）"
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
time.sleep(0.3)
s.recv(65536)
s.sendall(b"screendump /tmp/shuios-shot.ppm\n")
time.sleep(1.5)
try:
    print(s.recv(65536).decode(errors="replace"))
except Exception:
    pass
s.close()
PY
else
	echo "（monitor socket 不存在）"
fi

echo ">>> 关闭 QEMU"
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

if [ -f /tmp/shuios-shot.ppm ]; then
	if command -v convert >/dev/null 2>&1; then
		convert /tmp/shuios-shot.ppm "$SHOT" && echo "截图已保存: $SHOT"
	elif command -v pnmtopng >/dev/null 2>&1; then
		pnmtopng /tmp/shuios-shot.ppm > "$SHOT" && echo "截图已保存: $SHOT"
	else
		cp /tmp/shuios-shot.ppm "${SHOT%.png}.ppm"
		echo "未安装图像转换工具，保留 PPM: ${SHOT%.png}.ppm"
	fi
fi

echo
echo ">>> 关键标志检查"
ok=0
check() {
	if grep -qi -- "$1" "$OUT"; then
		echo "  [OK]   $2"
		ok=$((ok + 1))
	else
		echo "  [MISS] $2"
	fi
}

check "Linux version" "内核已启动"
check "squashfs" "squashfs 根已挂载"
check "systemd\[1\]" "systemd 作为 PID 1"
check "shuios-storage" "shuios-storage 已运行"
check "shuiosd" "shuiosd 已启动"
check "MCP" "MCP 总线已监听"
check "weston" "Weston 桌面已启动"
check "已提交\|boot-ok" "A/B 提交成功"
check "Reached target" "到达多用户目标"

echo
echo ">>> 串口日志尾部："
tail -n 25 "$OUT"

if [ "$ok" -ge 5 ]; then
	echo ">>> 冒烟测试通过（$ok 项）"
	exit 0
fi
echo ">>> 冒烟测试未通过（$ok 项）" >&2
exit 1
