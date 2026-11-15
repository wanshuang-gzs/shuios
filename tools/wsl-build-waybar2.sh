#!/bin/bash
# 重建 libxkbcommon（带 xkbregistry）然后继续构建 waybar
set -u
BR=/root/shuios/buildroot
EXT=/root/shuios/br2-ext

bash /tmp/wsl-enable-xkbregistry.sh || exit 1

cd "$BR" || exit 1
make -s BR2_EXTERNAL="$EXT" shuios_x86_64_defconfig >/dev/null 2>&1
echo ">>> libxml2 在 .config 里：$(grep -c '^BR2_PACKAGE_LIBXML2=y' .config)"

echo ">>> 重建 libxkbcommon"
make BR2_EXTERNAL="$EXT" BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12 \
	libxkbcommon-dirclean libxkbcommon > /tmp/xkb.log 2>&1
echo "    rc=$?"
tail -6 /tmp/xkb.log

echo ">>> 检查 xkbregistry.pc 是否出现"
ls output/staging/usr/lib/pkgconfig/xkbregistry.pc 2>/dev/null || echo "    (还没出现)"

echo ">>> 继续构建 waybar"
make BR2_EXTERNAL="$EXT" BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12 waybar \
	> /tmp/waybar-build2.log 2>&1
echo "    make rc=$?"
tail -20 /tmp/waybar-build2.log
