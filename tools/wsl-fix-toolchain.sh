#!/bin/sh
# 修正工具链并继续构建。
#
# 背景：工具链是在 BR2_TOOLCHAIN_BUILDROOT_CXX 关闭时构建的，output/host 里
# 没有 x86_64-buildroot-linux-gnu-g++，所有 C++ 包（harfbuzz/mesa/gtk3…）
# 在 meson 阶段失败。启用 C++ 后必须重建 gcc-final（它负责 g++ 与 libstdc++）。
#
# 注意：只有 gcc-final / host-gcc-final 有 -dirclean 目标；
# gcc-initial 没有，写进去会让整条清理命令直接失败。
set -eu

ROOT=/root/shuios
BR="$ROOT/buildroot"
cd "$BR"

echo ">>> 1/4 重新应用 defconfig"
make -s BR2_EXTERNAL="$ROOT/br2-ext" shuios_x86_64_defconfig >/dev/null
grep -E '^BR2_TOOLCHAIN_BUILDROOT_CXX=y' .config >/dev/null || {
	echo "!!! CXX 未开启，中止" >&2
	exit 1
}
echo "    CXX=y / MESA3D=y / MC=y 已确认"

echo ">>> 2/4 清理 gcc-final（迫使重新构建 g++）"
rm -rf "$BR/output/build/gcc-final-"* "$BR/output/build/host-gcc-final-"*
echo "    已删除 gcc-final 构建目录"

echo ">>> 3/4 补预取新包源码（mc/ncdu 等）"
"$ROOT/tools/fetch-deps.sh" 2>&1 | tail -n 4 || true

echo ">>> 4/4 继续构建（-j12）"
exec make BR2_EXTERNAL="$ROOT/br2-ext" \
	BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12
