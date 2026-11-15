#!/bin/bash
# 检查虚拟机里的帧缓冲设备（写自研开机动画要用）
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "===== /dev/fb* ====="
$SSH 'ls -l /dev/fb* 2>&1'

echo
echo "===== fbcon / drm ====="
$SSH 'ls /sys/class/graphics/ 2>&1; echo ---; dmesg 2>/dev/null | grep -i -e "fb0" -e "bochs" -e "virtio_gpu" | head -6'

echo
echo "===== 当前桌面进程 ====="
$SSH 'ps -eo comm | grep -E "weston|foot|shui" | sort | uniq -c'
