#!/bin/sh
# 同步仓库 → 重新应用 defconfig → 重打包镜像。
#
# 关键：必须重新跑 <board>_defconfig。Buildroot 不会把 defconfig 和 .config
# 做比较，改了 defconfig 但不重新应用，新加的包永远不会被构建
# （踩过：加了 BR2_PACKAGE_SWAY=y 却一直没编 sway）。
set -u

echo ">>> 同步仓库"
rsync -a --delete \
	--exclude '.cache' --exclude 'target' --exclude 'output' \
	--exclude 'buildroot' --exclude '.git' --exclude 'br2-ext/artifacts' \
	--exclude 'br2-ext/pkgrepo' \
	/mnt/d/shuios/ /root/shuios/

echo ">>> 编译 Rust 组件"
export PATH="$HOME/.cargo/bin:$PATH"
cd /root/shuios || exit 1
./tools/build-rust.sh >/tmp/rust.log 2>&1 || { echo "!!! Rust 编译失败"; tail -20 /tmp/rust.log; exit 1; }
ls -1 /root/shuios/br2-ext/artifacts

cd /root/shuios/buildroot || exit 1

echo ">>> 重新应用 defconfig"
make -s BR2_EXTERNAL=/root/shuios/br2-ext shuios_x86_64_defconfig >/dev/null
echo "    SWAYFX=$(grep -c '^BR2_PACKAGE_SWAYFX=y' .config) SWAYBAR=$(grep -c '^BR2_PACKAGE_SWAYFX_SWAYBAR=y' .config) WESTON=$(grep -c '^BR2_PACKAGE_WESTON=y' .config)"

echo ">>> 重新安装 shuios-runtime"
make -s BR2_EXTERNAL=/root/shuios/br2-ext shuios-runtime-reinstall >/dev/null 2>&1

echo ">>> 构建镜像"
make -s BR2_EXTERNAL=/root/shuios/br2-ext \
	BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12 > /tmp/repack.log 2>&1
rc=$?
echo "    make rc=$rc"
tail -n 5 /tmp/repack.log
if [ "$rc" -ne 0 ]; then
	echo "!!! 构建失败，不复制镜像（避免把旧镜像当新镜像用）"
	exit 1
fi
ls -lh output/images/shuios.img 2>/dev/null || echo "!!! 没有镜像"
cp -f output/images/shuios.img /root/test.img 2>/dev/null && echo ">>> 已复制到 /root/test.img"
