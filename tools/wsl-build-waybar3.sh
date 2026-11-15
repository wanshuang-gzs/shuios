#!/bin/bash
# 彻底重建 waybar（配置阶段必须能看到 xkbregistry）
set -u
BR=/root/shuios/buildroot
EXT=/root/shuios/br2-ext
cd "$BR" || exit 1

rsync -a /mnt/d/shuios/br2-ext/package/waybar/ "$EXT/package/waybar/" 2>/dev/null

make -s BR2_EXTERNAL="$EXT" shuios_x86_64_defconfig >/dev/null 2>&1

echo ">>> dirclean waybar 并重建（含依赖）"
make BR2_EXTERNAL="$EXT" BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12 \
	waybar-dirclean > /tmp/wb-clean.log 2>&1
make BR2_EXTERNAL="$EXT" BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12 waybar \
	> /tmp/waybar-build3.log 2>&1
echo "    make rc=$?"
tail -12 /tmp/waybar-build3.log

echo
echo ">>> 产物检查"
ls -l "$BR/output/target/usr/bin/waybar" 2>/dev/null || echo "    (还没有 waybar 二进制)"
