#!/bin/bash
# 从 WSL 里连进运行在 Windows 上的 shuios 虚拟机（QEMU hostfwd 绑 0.0.0.0）。
#
# Windows 的 127.0.0.1 与 WSL 的不是同一个网络栈，所以要走网关 IP。
set -u

GW=$(ip route | awk '/^default/ {print $3; exit}')
HOST="${SHUIOS_VM_HOST:-$GW}"
PORT="${SHUIOS_VM_PORT:-10022}"
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p $PORT root@$HOST"

echo ">>> 目标 ${HOST}:${PORT}"
if [ $# -gt 0 ]; then
	exec $SSH "$@"
fi

echo "===== 基本 ====="
$SSH 'hostname; uname -r'

echo
echo "===== seatd 单元状态 ====="
$SSH 'systemctl status seatd --no-pager -l 2>&1 | head -14'

echo
echo "===== seatd 日志 ====="
$SSH 'journalctl -u seatd --no-pager -n 20 2>&1 | tail -18'

echo
echo "===== seatd socket ====="
$SSH 'ls -l /run/seatd.sock 2>&1; ls -l /run | head -8'

echo
echo "===== 桌面单元状态 ====="
$SSH 'systemctl status shuios-desktop --no-pager -l 2>&1 | head -10'
