#!/bin/sh
# 把 Windows 侧的仓库同步进 WSL 的 ext4，然后修正工具链并继续构建。
#
# 用法（在 Windows 上）：
#   wsl -d shui-build -u root -- sh /mnt/d/shuios/tools/wsl-sync-and-build.sh
#
# 为什么不在 /mnt/d 上直接构建：9p 文件系统会让 Buildroot 慢 5~10 倍。
set -eu

SRC=/mnt/d/shuios
DST=/root/shuios

echo ">>> 同步仓库到 $DST"
mkdir -p "$DST"
rsync -a --delete \
	--exclude '.cache' \
	--exclude 'target' \
	--exclude 'output' \
	--exclude 'buildroot' \
	--exclude '.git' \
	"$SRC/" "$DST/"

echo ">>> 进入修正与构建流程"
exec sh "$DST/tools/wsl-fix-toolchain.sh"
