#!/bin/sh
# 重建内核并重新组装镜像（用于内核配置变更后）。
#
# 用法：wsl -d shui-build -u root -- sh /mnt/d/shuios/tools/wsl-rebuild-kernel.sh
set -eu

ROOT=/root/shuios
BR="$ROOT/buildroot"
cd "$BR"

echo ">>> 1/3 重新应用 defconfig（内核 fragment 变化会被感知）"
make -s BR2_EXTERNAL="$ROOT/br2-ext" shuios_x86_64_defconfig >/dev/null

echo ">>> 2/3 强制重建内核（删 build 目录以确保 fragment 生效）"
rm -rf "$BR/output/build/linux-"*
make -s BR2_EXTERNAL="$ROOT/br2-ext" \
	BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12 linux

echo ">>> 内核产物"
ls -lh "$BR/output/images/bzImage" 2>/dev/null || true

echo ">>> 3/3 重组镜像"
exec make -s BR2_EXTERNAL="$ROOT/br2-ext" \
	BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12
