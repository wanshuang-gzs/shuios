#!/bin/bash
# 把 tools/buildroot-deps/ 里的 recipe 覆盖到 Buildroot 树里。
#
# 为什么需要这个：Buildroot 不允许 br2-external 目录里出现与内置包同名的包
# （实测报 "Package 'libdrm' defined a second time"），所以升级内置包版本
# 只能直接改 Buildroot 树。为了可复现（重建树、换机器），
# 把改好的 recipe 放在 tools/buildroot-deps/ 下，由本脚本复制过去。
#
# 用法：bash tools/patch-buildroot-deps.sh [buildroot 路径]
#       默认路径 /root/shuios/buildroot
set -u

BR="${1:-/root/shuios/buildroot}"
SRC="$(cd "$(dirname "$0")" && pwd)/buildroot-deps"

if [ ! -d "$BR/package" ]; then
	echo "!!! 找不到 Buildroot 树：$BR"
	exit 1
fi

changed=0
for pkg in wlroots wayland wayland-protocols libdrm pixman xwayland; do
	# 个别包在 Buildroot 树里的位置不是 package/<名字>（xwayland 在 x11r7 下）
	case "$pkg" in
		xwayland) dst="$BR/package/x11r7/xwayland" ;;
		*)        dst="$BR/package/$pkg" ;;
	esac
	[ -d "$dst" ] || { echo "!!! Buildroot 里没有 $pkg 包，跳过"; continue; }

	for f in "$SRC/$pkg/$pkg.mk" "$SRC/$pkg/$pkg.hash"; do
		[ -f "$f" ] || continue
		base=$(basename "$f")
		# 首次改动前留一份原始备份，便于回滚
		if [ ! -f "$dst/$base.orig" ]; then
			cp -a "$dst/$base" "$dst/$base.orig"
		fi
		if ! cmp -s "$f" "$dst/$base"; then
			cp -a "$f" "$dst/$base"
			echo "    更新 $pkg/$base"
			changed=$((changed + 1))
		fi
	done
done

echo ">>> buildroot-deps 补丁完成（改动 $changed 个文件）"
echo "    校验版本："
for pkg in wlroots wayland wayland-protocols libdrm pixman; do
	v=$(grep -m1 '_VERSION = ' "$BR/package/$pkg/$pkg.mk" | sed 's/.*= *//')
	echo "    $pkg = $v"
done
echo "    xwayland glamor = $(grep -m1 '\-Dglamor=' "$BR/package/x11r7/xwayland/xwayland.mk" | sed 's/.*=-Dglamor=//')"
