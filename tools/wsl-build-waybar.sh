#!/bin/bash
# 构建 waybar（会顺带构建 gtkmm3 / gtk-layer-shell 等依赖）
set -u
BR=/root/shuios/buildroot
EXT=/root/shuios/br2-ext

echo ">>> 同步仓库"
rsync -a --delete \
	--exclude '.cache' --exclude 'target' --exclude 'output' \
	--exclude 'buildroot' --exclude '.git' --exclude 'br2-ext/artifacts' \
	--exclude 'br2-ext/pkgrepo' \
	/mnt/d/shuios/ /root/shuios/ || exit 1

cd "$BR" || exit 1
echo ">>> 应用 defconfig"
make -s BR2_EXTERNAL="$EXT" shuios_x86_64_defconfig >/dev/null 2>&1 || exit 1

echo ">>> 确认关键选项进了 .config"
for s in BR2_PACKAGE_GTK_LAYER_SHELL BR2_PACKAGE_WAYBAR BR2_PACKAGE_GTKMM3 BR2_PACKAGE_LIBSIGC BR2_PACKAGE_JSONCPP; do
	printf "    %-32s %s\n" "$s" "$(grep -c "^$s=y" .config)"
done

echo ">>> 构建 waybar（含依赖，可能 20~40 分钟）"
make BR2_EXTERNAL="$EXT" BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12 waybar \
	> /tmp/waybar-build.log 2>&1
rc=$?
echo "    make rc=$rc"
tail -25 /tmp/waybar-build.log
