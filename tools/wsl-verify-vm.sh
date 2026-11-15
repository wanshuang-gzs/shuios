#!/bin/bash
# 进入正在运行的 shuios 虚拟机做功能验收（SSH 端口 10022）。
set -u

SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@127.0.0.1"

echo "===== 基本连通 ====="
$SSH 'hostname; uname -r' || { echo "SSH 失败"; exit 1; }

echo
echo "===== 关键服务 ====="
$SSH 'systemctl is-active seatd weston shuiosd sshd'

echo
echo "===== 显示设备 ====="
$SSH 'ls -l /dev/dri'

echo
echo "===== shuios 运行时 ====="
$SSH 'shui-ctl status' || true

echo
echo "===== MCP 总线 ====="
$SSH 'shui-ctl mcp' || true

echo
echo "===== 根是否只读 ====="
$SSH 'mount | grep -E " / | /workspace | /data " | head -5'

echo
echo "===== 模型挑选 ====="
$SSH 'shui-ctl model-select; echo "(退出码 $?)"' || true
