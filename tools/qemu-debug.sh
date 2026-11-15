#!/bin/bash
# 启动 shuios 虚拟机（后台常驻），并开 SSH 端口转发，方便进去诊断。
#
# 用法：
#   bash tools/qemu-debug.sh start [镜像]
#   bash tools/qemu-debug.sh ssh  <命令...>
#   bash tools/qemu-debug.sh shot [输出png]
#   bash tools/qemu-debug.sh stop
set -u

IMG="${SHUIOS_IMG:-/root/test.img}"
SERIAL=/tmp/shuios-serial.log
MON=/tmp/shuios-mon.sock
QOUT=/tmp/shuios-qemu.out
SSH_PORT=10022

ovmf() {
	for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
	         /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.fd; do
		[ -f "$c" ] && { echo "$c"; return 0; }
	done
	return 1
}

start() {
	pkill -9 -f qemu-system 2>/dev/null || true
	sleep 1
	rm -f "$SERIAL" "$MON" "$QOUT"
	OVMF=$(ovmf) || { echo "缺少 OVMF"; exit 1; }
	case "$OVMF" in
		*OVMF_CODE_4M.fd) VARS_SRC="${OVMF%_CODE_4M.fd}_VARS_4M.fd" ;;
		*)                VARS_SRC="${OVMF%_CODE.fd}_VARS.fd" ;;
	esac
	VARS=$(mktemp /tmp/shuios-vars.XXXXXX)
	[ -f "$VARS_SRC" ] && cp -f "$VARS_SRC" "$VARS"

	# setsid + nohup：脱离 WSL 会话，否则 wsl.exe 返回后 QEMU 会被一起杀掉
	setsid nohup qemu-system-x86_64 \
		-machine q35 -cpu max -m 4096 -smp 4 \
		-drive if=pflash,format=raw,readonly=on,file="$OVMF" \
		-drive if=pflash,format=raw,file="$VARS" \
		-drive file="$IMG",format=raw,if=ide,index=0 \
		-netdev user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22 \
		-device e1000,netdev=n0 \
		-vga std -display none \
		-serial file:"$SERIAL" \
		-monitor unix:"$MON",server,nowait \
		> "$QOUT" 2>&1 < /dev/null &
	echo "QEMU 已启动（ssh 端口 ${SSH_PORT}）"
	sleep 3
	pgrep -c -f qemu-system >/dev/null 2>&1 && echo "  进程存活" || { echo "  进程未存活，输出："; cat "$QOUT"; }
}

ssh_run() {
	sshpass -p shui ssh -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
		-p "$SSH_PORT" root@127.0.0.1 "$@"
}

shot() {
	OUT="${1:-/mnt/d/shuios/shuios-desktop.png}"
	rm -f /tmp/shot.ppm
	timeout 20 python3 - "$MON" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1]); time.sleep(0.3); s.recv(65536)
s.sendall(b"screendump /tmp/shot.ppm\n"); time.sleep(2)
try: print(s.recv(65536).decode(errors="replace").strip())
except Exception: pass
s.close()
PY
	if [ -f /tmp/shot.ppm ]; then
		convert /tmp/shot.ppm "$OUT" 2>/dev/null || cp /tmp/shot.ppm "${OUT%.png}.ppm"
		echo "截图: $OUT ($(stat -c%s "$OUT" 2>/dev/null) 字节)"
	fi
}

stop() {
	pkill -9 -f qemu-system 2>/dev/null || true
	echo "已停止"
}

case "${1:-}" in
	start) shift; start ;;
	ssh)   shift; ssh_run "$@" ;;
	shot)  shift; shot "${1:-/mnt/d/shuios/shuios-desktop.png}" ;;
	stop)  stop ;;
	*) echo "用法: $0 {start|ssh <cmd>|shot [png]|stop}"; exit 2 ;;
esac
