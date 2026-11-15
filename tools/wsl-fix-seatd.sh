#!/bin/sh
# 强制重建 seatd（让 daemon 与 libseat 的 seatd 后端生效），然后重打包镜像。
#
# 为什么需要：weston 依赖 libseat，而 libseat 由 seatd 包提供。weston 构建时
# 自动选中了 BR2_PACKAGE_SEATD_BUILTIN，只编了 builtin 后端。后来打开
# BR2_PACKAGE_SEATD_DAEMON，Buildroot 不会自动重建已构建的包，
# 于是 /usr/bin/seatd 与 seatd.service 都不存在，libseat 也仍然只有
# logind/builtin 后端 → Weston 报 "No backend was able to open a seat"。
set -u

BR=/root/shuios/buildroot
cd "$BR" || exit 1

echo ">>> 1/5 重新应用 defconfig"
rsync -a --delete \
	--exclude '.cache' --exclude 'target' --exclude 'output' \
	--exclude 'buildroot' --exclude '.git' --exclude 'br2-ext/artifacts' \
	/mnt/d/shuios/ /root/shuios/
make -s BR2_EXTERNAL=/root/shuios/br2-ext shuios_x86_64_defconfig >/dev/null
grep -E '^BR2_PACKAGE_SEATD' .config

echo ">>> 2/5 清理 seatd 与 weston 的构建目录"
rm -rf "$BR/output/build/seatd-"*
rm -rf "$BR/output/build/weston-"*

echo ">>> 3/5 重新构建"
make -s BR2_EXTERNAL=/root/shuios/br2-ext \
	BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12 > /tmp/repack4.log 2>&1
echo "    make rc=$?"
tail -n 5 /tmp/repack4.log

echo ">>> 4/5 校验 seatd 产物"
T="$BR/output/target"
ls -l "$T/usr/bin/seatd" 2>/dev/null || echo "!!! 没有 /usr/bin/seatd"
ls -l "$T/usr/lib/systemd/system/seatd.service" 2>/dev/null || echo "!!! 没有 seatd.service"

echo ">>> 5/5 复制镜像"
cp -f "$BR/output/images/shuios.img" /root/test.img 2>/dev/null && ls -lh /root/test.img
