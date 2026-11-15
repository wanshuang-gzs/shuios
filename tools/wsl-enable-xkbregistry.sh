#!/bin/bash
# 让 Buildroot 的 libxkbcommon 编出 xkbregistry（waybar 的 sway/language 模块要用）。
#
# 为什么必须改构建树（而不是用 BR2_EXTERNAL）：meson 的 -Denable-xkbregistry
# 写在 Buildroot 自带包的 .mk 里，外部树无法覆盖同名的上游包，
# 而 Buildroot 又不支持用 patch 改 .mk。所以做成一个**幂等**脚本，
# 每次同步/构建前跑一次即可（wsl-build-waybar.sh 会自动调用）。
set -u
MK=/root/shuios/buildroot/package/libxkbcommon/libxkbcommon.mk
CFG=/root/shuios/buildroot/package/libxkbcommon/Config.in

[ -f "$MK" ] || { echo "!!! 找不到 $MK"; exit 1; }

changed=0

# 1) 打开 xkbregistry
if grep -q -- '-Denable-xkbregistry=false' "$MK"; then
	sed -i 's/-Denable-xkbregistry=false/-Denable-xkbregistry=true/' "$MK"
	changed=1
fi

# 2) 它需要 libxml2
if ! grep -q 'libxml2' "$MK"; then
	sed -i 's/^LIBXKBCOMMON_DEPENDENCIES = host-bison host-flex$/LIBXKBCOMMON_DEPENDENCIES = host-bison host-flex libxml2/' "$MK"
	changed=1
fi

# 3) 打开 libxml2 这个包选项（select 更干净，但直接改 Config.in 也行）
if ! grep -q 'select BR2_PACKAGE_LIBXML2' "$CFG"; then
	sed -i 's/^\tselect BR2_PACKAGE_LIBXCB if BR2_PACKAGE_XORG7$/\tselect BR2_PACKAGE_LIBXCB if BR2_PACKAGE_XORG7\n\tselect BR2_PACKAGE_LIBXML2/' "$CFG"
	changed=1
fi

if [ "$changed" -eq 1 ]; then
	echo ">>> 已修改 libxkbcommon（xkbregistry + libxml2）"
	grep -nE "xkbregistry|DEPENDENCIES = " "$MK" | head -4
else
	echo ">>> libxkbcommon 已经改过了（xkbregistry 已开）"
fi
