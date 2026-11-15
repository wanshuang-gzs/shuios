#!/bin/sh
# 同步仓库到 WSL 的 ext4，然后继续构建。
#
# 关键：必须排除 br2-ext/artifacts —— 那里面是 tools/build-rust.sh 在 WSL 里
# 编译出来的 Rust 二进制。Windows 侧该目录只有 README.md，如果参与 --delete，
# 每同步一次就会把已编好的二进制删掉，导致 shuios-runtime 包报
# 「缺少预编译二进制」。
set -eu

SRC=/mnt/d/shuios
DST=/root/shuios

echo ">>> 同步仓库到 $DST（保护 artifacts）"
mkdir -p "$DST"
rsync -a --delete \
	--exclude '.cache' \
	--exclude 'target' \
	--exclude 'output' \
	--exclude 'buildroot' \
	--exclude '.git' \
	--exclude 'br2-ext/artifacts' \
	"$SRC/" "$DST/"

exec sh "$DST/tools/wsl-continue.sh"
