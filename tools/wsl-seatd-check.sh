#!/bin/sh
# 检查 seatd / libseat 在目标 rootfs 与构建目录里的状态。
set -u
T=/root/shuios/buildroot/output/target
B=/root/shuios/buildroot/output/build

echo "===== 目标 rootfs 里的 seat 相关文件 ====="
find "$T" -name '*seat*' 2>/dev/null | head -10 || true

echo
echo "===== 构建目录 ====="
ls -d "$B"/seatd* 2>/dev/null || echo "(没有 seatd 构建目录)"

echo
echo "===== .config 相关 ====="
grep -E '^BR2_PACKAGE_SEATD' /root/shuios/buildroot/.config || echo "(无)"

echo
echo "===== 最近一次构建日志里的 seatd ====="
grep -i -e seatd /tmp/repack3.log 2>/dev/null | head -8 || echo "(日志无 seatd)"

echo
echo "===== libseat 是否存在 ====="
find "$T" -name 'libseat*' 2>/dev/null | head -5 || true
