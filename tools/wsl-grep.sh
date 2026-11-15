#!/bin/sh
# 在 WSL 里 grep。用法：
#   wsl -d shui-build -u root -- sh /mnt/d/shuios/tools/wsl-grep.sh "<正则>" [路径]
set -u
PAT="$1"
TARGET="${2:-/root/shuios/buildroot/.config}"
if [ $# -eq 0 ]; then
	echo "用法: $0 <正则> [路径]"
	exit 2
fi
if [ ! -e "$TARGET" ]; then
	echo "(不存在: $TARGET)"
	exit 1
fi
grep -rnE "$PAT" "$TARGET" 2>/dev/null | head -25 || echo "(没有匹配)"
